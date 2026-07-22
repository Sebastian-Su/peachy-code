import AppKit
import Foundation

struct AgentSession: Identifiable, Codable {
    let id: String // session_id from hook event
    let projectDir: String?
    let projectName: String?
    var agentSource: AgentSource = .claudeCode
    /// Raw source string before normalization (e.g. "vscode" for Codex Desktop),
    /// used to distinguish Codex Desktop (GUI app) from Codex CLI (terminal).
    var rawSource: String?
    var status: Status
    var phase: Phase = .idle
    var eventCount: Int
    var startedAt: Date
    var lastEventAt: Date?
    var lastToolName: String?
    var activeSubagentCount: Int = 0
    var terminalPid: Int?
    var terminalBundleId: String?
    var shellPid: Int?
    var transcriptPath: String?
    var idleUntil: Date?

    var isCompacting: Bool { phase == .compacting }

    /// Codex Desktop (ChatGPT.app) is a GUI app with no terminal — focus should
    /// activate the app directly rather than resolving a terminal window.
    var isCodexDesktop: Bool {
        let s = (rawSource ?? "").lowercased()
        return s == "vscode" || s.contains("desktop")
    }

    /// The app bundle id whose icon best represents this session's terminal/client.
    /// Matches IDETerminalFocus.focusSession's activation target so the icon == where a click goes.
    var focusAppBundleId: String? {
        if isCodexDesktop { return "com.openai.codex" }   // ChatGPT.app
        if let bundleId = terminalBundleId { return bundleId }
        // terminalBundleId may be nil for older sessions even when terminalPid is known.
        // Fall back to a live NSRunningApplication lookup so existing sessions also get icons.
        if let pid = terminalPid,
           let bid = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier {
            return bid
        }
        return nil
    }

    init(
        id: String,
        projectDir: String?,
        projectName: String?,
        agentSource: AgentSource = .claudeCode,
        status: Status,
        phase: Phase = .idle,
        eventCount: Int,
        startedAt: Date,
        lastEventAt: Date?,
        lastToolName: String? = nil,
        activeSubagentCount: Int = 0,
        terminalPid: Int? = nil,
        shellPid: Int? = nil,
        transcriptPath: String? = nil
    ) {
        self.id = id
        self.projectDir = projectDir
        self.projectName = projectName
        self.agentSource = agentSource
        self.status = status
        self.phase = phase
        self.eventCount = eventCount
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.lastToolName = lastToolName
        self.activeSubagentCount = activeSubagentCount
        self.terminalPid = terminalPid
        self.shellPid = shellPid
        self.transcriptPath = transcriptPath
    }

    enum Status: String, Codable {
        case active, ended

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw == "active" ? .active : .ended
        }
    }

    enum Phase: String, Codable {
        case idle       // After Stop or SessionStart — waiting for user input
        case running    // After UserPromptSubmit or tool use — agent is working
        case compacting // After PreCompact — context compaction in progress
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectDir
        case projectName
        case agentSource
        case rawSource
        case status
        case phase
        case eventCount
        case startedAt
        case lastEventAt
        case lastToolName
        case activeSubagentCount
        case terminalPid
        case shellPid
        case transcriptPath
        case idleUntil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectDir = try container.decodeIfPresent(String.self, forKey: .projectDir)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        if let source = try container.decodeIfPresent(AgentSource.self, forKey: .agentSource) {
            agentSource = source
        } else {
            enum LegacyCodingKeys: String, CodingKey { case assistantSource }
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let legacySource = try legacyContainer.decodeIfPresent(String.self, forKey: .assistantSource) {
                agentSource = AgentSource(rawSource: legacySource)
            } else {
                agentSource = .unknown
            }
        }
        status = try container.decode(Status.self, forKey: .status)
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastEventAt = try container.decodeIfPresent(Date.self, forKey: .lastEventAt)
        lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        activeSubagentCount = try container.decodeIfPresent(Int.self, forKey: .activeSubagentCount) ?? 0
        terminalPid = try container.decodeIfPresent(Int.self, forKey: .terminalPid)
        shellPid = try container.decodeIfPresent(Int.self, forKey: .shellPid)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        rawSource = try container.decodeIfPresent(String.self, forKey: .rawSource)
        idleUntil = try container.decodeIfPresent(Date.self, forKey: .idleUntil)
    }
}

@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    private static let filename = "sessions.json"
    static let assistantProcessMatchers: [[String]] = [
        ["-x", "claude"],
        ["-x", "codex"],
        ["-x", "Codex"],
        ["-f", "codex_cli_rs"],
        // Codex desktop runs as an app bundle process (not "Codex Desktop").
        ["-f", "Codex.app"],
        // Keep legacy matcher for compatibility with older process naming.
        ["-f", "Codex Desktop"],
    ]
    private var reconcileTimer: Timer?
    private var interruptWatcherTimer: Timer?
    private var idleExpiryTimer: Timer?
    private let idleRetentionDuration: TimeInterval
    /// Snapshots for in-progress potentially-internal turns.
    private var internalTurnSnapshots: [String: (
        existed: Bool,
        status: AgentSession.Status,
        phase: AgentSession.Phase,
        idleUntil: Date?,
        activeSubagentIds: Set<String>,
        anonymousSubagentCount: Int,
        reconciledSubagentStopIds: Set<String>
    )] = [:]
    /// Track active subagent IDs per session to prevent double-counting
    private var activeSubagentIds: [String: Set<String>] = [:]
    /// Track anonymous subagent events separately from identified agents
    private var anonymousSubagentCounts: [String: Int] = [:]
    /// Identified stop events that consumed an anonymous subagent; prevents duplicate stops from decrementing again.
    private var reconciledSubagentStopIds: [String: Set<String>] = [:]

    /// Called when session phases or active subagent counts change.
    /// Wire this to refresh overlay and session switcher snapshots.
    var onPhasesChanged: (() -> Void)?

    init(idleRetentionDuration: TimeInterval = 300) {
        self.idleRetentionDuration = idleRetentionDuration
        sessions = LocalStorage.load([AgentSession].self, from: Self.filename) ?? []
        // On launch, no session can be mid-compact - reset any stale compacting phase
        var needsPersist = false
        for i in sessions.indices where sessions[i].phase == .compacting {
            sessions[i].phase = .idle
            needsPersist = true
        }
        if needsPersist { persist() }
        runStartupMigration()
        reconcileIfNeeded()
        startReconcileTimer()
        startInterruptWatcher()
    }

    /// Safety net: check every 2 minutes if assistant processes are still alive.
    /// Catches the edge case where SessionEnd hook was never delivered (crash, SIGKILL).
    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.reconcileIfNeeded()
            }
        }
    }

    /// Check every 3 seconds if any running sessions were interrupted.
    /// Claude Code does not fire a hook on user interrupt, but it does write
    /// `[Request interrupted by user]` to the transcript JSONL file.
    private func startInterruptWatcher() {
        interruptWatcherTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkForInterrupts()
            }
        }
    }

    /// Read the tail of each running session's transcript to detect interrupts.
    private func checkForInterrupts() {
        // Collect data needed for background I/O
        let candidates: [(index: Int, id: String, path: String, lastEventAt: Date?)] = sessions.indices.compactMap {
            guard sessions[$0].status == .active,
                  sessions[$0].phase == .running,
                  let path = sessions[$0].transcriptPath else { return nil }
            return ($0, sessions[$0].id, path, sessions[$0].lastEventAt)
        }
        guard !candidates.isEmpty else { return }

        // File I/O on background queue to avoid blocking main thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let interrupted = candidates.filter {
                Self.transcriptIndicatesInterrupt(path: $0.path, since: $0.lastEventAt)
            }
            guard !interrupted.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                var changed = false
                for candidate in interrupted {
                    // Re-verify index is still valid and session hasn't changed
                    guard candidate.index < self.sessions.count,
                          self.sessions[candidate.index].id == candidate.id,
                          self.sessions[candidate.index].phase == .running else { continue }
                    self.sessions[candidate.index].phase = .idle
                    self.clearSubagents(at: candidate.index)
                    self.setIdleUntil(for: candidate.id)
                    changed = true
                    PeachyLog.session.info("Session interrupted: \(candidate.id) → idle")
                }
                if changed {
                    self.persist()
                    self.onPhasesChanged?()
                }
            }
        }
    }

    /// Read the last ~4KB of a transcript JSONL file and check if the most recent
    /// non-progress entry is `[Request interrupted by user]`.
    private static func transcriptIndicatesInterrupt(path: String, since lastEventAt: Date?) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return false }
        let readSize = min(UInt64(4096), fileSize)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Walk backwards to find the last meaningful entry (skip "progress" lines)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = obj["type"] as? String ?? ""
            if type == "progress" || type == "file-history-snapshot" || type == "summary" { continue }

            // Check timestamp — only act on entries newer than our last hook event.
            // Exception: if the session has been running for a long time without a Stop hook
            // (e.g. user killed the process), allow matching interrupt entries regardless of age.
            let staleCutoffMinutes: Double = 10
            if let timestamp = obj["timestamp"] as? String, let lastEventAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var entryDate = formatter.date(from: timestamp)
                if entryDate == nil {
                    // Retry without fractional seconds
                    formatter.formatOptions = [.withInternetDateTime]
                    entryDate = formatter.date(from: timestamp)
                }
                if let entryDate, entryDate <= lastEventAt {
                    // Entry is older than our last hook event.
                    // If the session has been idle for a long time, still check for interrupt
                    // (the interrupt may have happened before the last hook event we received).
                    let sessionAge = -lastEventAt.timeIntervalSinceNow / 60
                    if sessionAge < staleCutoffMinutes {
                        return false // Recent session — stale entry, skip
                    }
                    // Old session — fall through and check if it's an interrupt entry
                }
                // If timestamp still can't be parsed, treat as stale to avoid false positives
                if entryDate == nil {
                    return false
                }
            }

            // Check if this is an interrupt entry
            if type == "user",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let firstItem = content.first,
               let text = firstItem["text"] as? String,
               text.contains("[Request interrupted by user]"),
               !text.contains("for tool use") {
                return true
            }

            // Found a non-progress, non-interrupt entry — session is not interrupted
            return false
        }
        return false
    }

    /// Invalidate all timers — called on app termination
    func stopTimers() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        interruptWatcherTimer?.invalidate()
        interruptWatcherTimer = nil
        idleExpiryTimer?.invalidate()
        idleExpiryTimer = nil
    }

    deinit {
        reconcileTimer?.invalidate()
        interruptWatcherTimer?.invalidate()
        idleExpiryTimer?.invalidate()
    }

    // MARK: - Crash Recovery

    /// Check for crashed assistant processes and mark orphaned sessions as ended.
    /// Called on init and when the app comes to foreground.
    func reconcileIfNeeded() {
        guard !activeSessions.isEmpty else { return }

        // Run process checks on a background thread to avoid blocking the UI
        checkForAssistantProcesses { [weak self] hasAssistantProcess in
            DispatchQueue.main.async {
                self?.applyReconciliation(hasAssistantProcess: hasAssistantProcess)
            }
        }
    }

    private func applyReconciliation(hasAssistantProcess: Bool) {
        guard !activeSessions.isEmpty else { return }

        var changed = false

        // 1. If no assistant process at all, end everything
        if !hasAssistantProcess {
            for i in sessions.indices where sessions[i].status == .active {
                sessions[i].status = .ended
                sessions[i].phase = .idle
                clearSubagents(at: i)
                PeachyLog.session.warning("Session ended (no process): \(self.sessions[i].id)")
                changed = true
            }
        } else {
            // 2. End individual sessions that are stale (no events in 1+ hour).
            // A process exists for a different session - but these old ones are dead.
            let staleThreshold: TimeInterval = 3600 // 1 hour
            let now = Date()
            for i in sessions.indices where sessions[i].status == .active {
                if let lastEvent = sessions[i].lastEventAt,
                   now.timeIntervalSince(lastEvent) > staleThreshold {
                    // Check if transcript was recently modified before killing
                    if let path = sessions[i].transcriptPath,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                       let modDate = attrs[.modificationDate] as? Date,
                       now.timeIntervalSince(modDate) < 300 { // 5 min
                        continue // transcript still active, skip
                    }
                    sessions[i].status = .ended
                    sessions[i].phase = .idle
                    clearSubagents(at: i)
                    changed = true
                }
            }
        }

        if changed {
            persist()
            onPhasesChanged?()
        }
    }

    /// Check if any Claude or Codex process is running.
    /// Runs on a background thread to avoid blocking the main/UI thread.
    private func checkForAssistantProcesses(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let hasAssistant = Self.assistantProcessMatchers.contains { matcher in
                Self.isProcessRunning(arguments: matcher)
            }
            completion(hasAssistant)
        }
    }

    private static func isProcessRunning(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 // 0 = found matches
        } catch {
            return false
        }
    }

    private func updateSubagentCount(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let sessionId = sessions[index].id
        let identifiedCount = activeSubagentIds[sessionId]?.count ?? 0
        let anonymousCount = anonymousSubagentCounts[sessionId] ?? 0
        sessions[index].activeSubagentCount = identifiedCount + anonymousCount
    }

    private func clearSubagents(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let sessionId = sessions[index].id
        activeSubagentIds.removeValue(forKey: sessionId)
        anonymousSubagentCounts.removeValue(forKey: sessionId)
        reconciledSubagentStopIds.removeValue(forKey: sessionId)
        sessions[index].activeSubagentCount = 0
    }

    // MARK: - Persistence

    private func persist() {
        LocalStorage.save(sessions, to: Self.filename)
    }

    // MARK: - Idle Retention

    private func setIdleUntil(for sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].idleUntil = Date(timeIntervalSinceNow: idleRetentionDuration)
        scheduleIdleExpiryTimer()
    }

    private func clearIdleUntil(for sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].idleUntil = nil
    }

    /// Ends all sessions whose idleUntil has passed. Called by timer and in tests.
    /// Also expires active+idle sessions that have no idleUntil but whose lastEventAt
    /// is older than idleRetentionDuration (handles sessions that never received a Stop).
    func expireIdleSessions() {
        let now = Date()
        var changed = false
        for i in sessions.indices {
            guard sessions[i].status == .active,
                  sessions[i].phase == .idle else { continue }
            if let idleUntil = sessions[i].idleUntil {
                if idleUntil <= now {
                    sessions[i].status = .ended
                    sessions[i].idleUntil = nil
                    clearSubagents(at: i)
                    PeachyLog.session.info("Session expired (idle timeout): \(self.sessions[i].id) project=\(self.sessions[i].projectName ?? "/")")
                    changed = true
                }
            } else {
                // No idleUntil: session went idle without a Stop event (e.g. Codex Desktop JSONL).
                // Use lastEventAt + retention as implicit expiry.
                let ref = sessions[i].lastEventAt ?? sessions[i].startedAt
                if ref.addingTimeInterval(idleRetentionDuration) <= now {
                    sessions[i].status = .ended
                    clearSubagents(at: i)
                    PeachyLog.session.info("Session expired (idle timeout): \(self.sessions[i].id) project=\(self.sessions[i].projectName ?? "/")")
                    changed = true
                }
            }
        }
        if changed {
            persist()
            onPhasesChanged?()
        }
        scheduleIdleExpiryTimer()
    }

    private func scheduleIdleExpiryTimer() {
        idleExpiryTimer?.invalidate()
        // Compute the nearest expiry: from explicit idleUntil, or implicit lastEventAt + retention
        let explicitExpiry = sessions.compactMap { s -> Date? in
            guard s.status == .active else { return nil }
            return s.idleUntil
        }.min()
        let implicitExpiry = sessions.compactMap { s -> Date? in
            guard s.status == .active, s.phase == .idle, s.idleUntil == nil else { return nil }
            let ref = s.lastEventAt ?? s.startedAt
            return ref.addingTimeInterval(idleRetentionDuration)
        }.min()
        let candidates = [explicitExpiry, implicitExpiry].compactMap { $0 }
        guard let nextExpiry = candidates.min() else { return }
        let delay = max(0, nextExpiry.timeIntervalSinceNow)
        idleExpiryTimer = Timer.scheduledTimer(withTimeInterval: delay + 0.1, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.expireIdleSessions() }
        }
    }

    // MARK: - Internal Turn Snapshot & Rollback

    /// Called by EventProcessor BEFORE recordEvent for a userPromptSubmit that carries a taskId.
    func saveSnapshot(taskId: String, sessionId: String) {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            internalTurnSnapshots[taskId] = (
                existed: true,
                status: session.status,
                phase: session.phase,
                idleUntil: session.idleUntil,
                activeSubagentIds: activeSubagentIds[sessionId] ?? [],
                anonymousSubagentCount: anonymousSubagentCounts[sessionId] ?? 0,
                reconciledSubagentStopIds: reconciledSubagentStopIds[sessionId] ?? []
            )
        } else {
            internalTurnSnapshots[taskId] = (
                existed: false,
                status: .ended,
                phase: .idle,
                idleUntil: nil,
                activeSubagentIds: [],
                anonymousSubagentCount: 0,
                reconciledSubagentStopIds: []
            )
        }
    }

    /// Called by EventProcessor when an internalResult arrives. Restores pre-turn state.
    func rollbackInternalTurn(taskId: String, sessionId: String) {
        defer { internalTurnSnapshots.removeValue(forKey: taskId) }
        guard let snapshot = internalTurnSnapshots[taskId] else { return }
        if !snapshot.existed {
            activeSubagentIds.removeValue(forKey: sessionId)
            anonymousSubagentCounts.removeValue(forKey: sessionId)
            reconciledSubagentStopIds.removeValue(forKey: sessionId)
            sessions.removeAll(where: { $0.id == sessionId })
            PeachyLog.session.debug("Internal turn rolled back: taskId=\(taskId) sessionId=\(sessionId)")
            persist()
            onPhasesChanged?()
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        // If the session has no terminal, was never stopped (no idleUntil), and was only
        // created by SessionStart + internal turns (Codex approval-only JSONL), remove it
        // entirely rather than leaving a phantom idle entry.
        let s = sessions[index]
        if s.terminalPid == nil && s.idleUntil == nil && s.eventCount <= 2 && snapshot.phase == .idle {
            activeSubagentIds.removeValue(forKey: sessionId)
            anonymousSubagentCounts.removeValue(forKey: sessionId)
            reconciledSubagentStopIds.removeValue(forKey: sessionId)
            sessions.remove(at: index)
            persist()
            onPhasesChanged?()
            return
        }
        let previousStatus = sessions[index].status
        let previousPhase = sessions[index].phase
        let previousCount = sessions[index].activeSubagentCount
        sessions[index].status = snapshot.status
        sessions[index].phase = snapshot.phase
        sessions[index].idleUntil = snapshot.idleUntil
        if snapshot.status == .ended || snapshot.phase == .idle {
            clearSubagents(at: index)
        } else {
            activeSubagentIds[sessionId] = snapshot.activeSubagentIds
            anonymousSubagentCounts[sessionId] = snapshot.anonymousSubagentCount
            reconciledSubagentStopIds[sessionId] = snapshot.reconciledSubagentStopIds
            updateSubagentCount(at: index)
        }
        persist()
        if sessions[index].status != previousStatus
            || sessions[index].phase != previousPhase
            || sessions[index].activeSubagentCount != previousCount {
            onPhasesChanged?()
        }
    }

    /// Called by EventProcessor when a real stop arrives for a taskId that had a snapshot.
    func discardSnapshot(taskId: String) {
        internalTurnSnapshots.removeValue(forKey: taskId)
    }

    // MARK: - Startup Migration

    func runStartupMigration() {
        let now = Date()
        var changed = false
        for i in sessions.indices {
            let hadPersistedSubagents = sessions[i].activeSubagentCount > 0
            clearSubagents(at: i)
            if hadPersistedSubagents { changed = true }
            guard sessions[i].status == .active else { continue }
            switch sessions[i].phase {
            case .idle:
                if let idleUntil = sessions[i].idleUntil {
                    if idleUntil <= now {
                        sessions[i].status = .ended
                        sessions[i].idleUntil = nil
                        PeachyLog.session.info("Session ended (startup migration): \(self.sessions[i].id) project=\(self.sessions[i].projectName ?? "/")")
                        changed = true
                    }
                } else {
                    // Old session without idleUntil: compute from lastEventAt or startedAt
                    let ref = sessions[i].lastEventAt ?? sessions[i].startedAt
                    let computed = ref.addingTimeInterval(idleRetentionDuration)
                    if computed <= now {
                        sessions[i].status = .ended
                        PeachyLog.session.info("Session ended (startup migration): \(self.sessions[i].id) project=\(self.sessions[i].projectName ?? "/")")
                        changed = true
                    } else {
                        sessions[i].idleUntil = computed
                        changed = true
                    }
                }
            case .running, .compacting:
                // A running/compacting session with no recent events and no terminalPid is a
                // headless agent (e.g. namiwork Claude Code) that exited without sending Stop.
                // Treat it the same as idle: expire after idleRetentionDuration from lastEventAt.
                guard sessions[i].terminalPid == nil else { break }
                let ref = sessions[i].lastEventAt ?? sessions[i].startedAt
                let staleAt = ref.addingTimeInterval(idleRetentionDuration)
                if staleAt <= now {
                    sessions[i].status = .ended
                    sessions[i].phase = .idle
                    PeachyLog.session.info("Session ended (startup migration): \(self.sessions[i].id) project=\(self.sessions[i].projectName ?? "/")")
                    changed = true
                }
            }
        }
        if changed { persist() }
        scheduleIdleExpiryTimer()
    }

    // MARK: - Test Support

    func injectSessionForTesting(_ session: AgentSession) {
        sessions.removeAll(where: { $0.id == session.id })
        sessions.insert(session, at: 0)
    }

    // MARK: - Computed Properties

    var activeSessions: [AgentSession] {
        sessions.filter { $0.status == .active }
    }

    var runningSessions: [AgentSession] {
        activeSessions.filter { $0.phase == .running }
    }

    var idleSessions: [AgentSession] {
        activeSessions.filter { $0.phase == .idle }
    }

    var totalActiveSubagents: Int {
        activeSessions.reduce(0) { $0 + $1.activeSubagentCount }
    }

    var totalCompactCount: Int {
        activeSessions.filter { $0.phase == .compacting }.count
    }

    // MARK: - Event Recording

    func recordEvent(_ event: AgentEvent) {
        guard let sessionId = event.sessionId, !sessionId.isEmpty else { return }
        var shouldNotifyObservers = false

        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            let previousSubagentCount = sessions[index].activeSubagentCount
            sessions[index].eventCount += 1
            sessions[index].lastEventAt = Date()
            if let toolName = event.toolName {
                sessions[index].lastToolName = toolName
            }
            if let source = event.source, !source.isEmpty {
                sessions[index].agentSource = AgentSource(rawSource: source)
                sessions[index].rawSource = source
            }
            if let path = event.transcriptPath, sessions[index].transcriptPath == nil {
                sessions[index].transcriptPath = path
            }
            if let pid = event.terminalPid, sessions[index].terminalPid == nil {
                sessions[index].terminalPid = pid
                sessions[index].terminalBundleId = Self.resolveBundleId(pid: pid)
            }
            if let pid = event.shellPid, sessions[index].shellPid == nil {
                sessions[index].shellPid = pid
            }

            // Reactivate ended sessions when active-work events arrive
            // (handles app restart while Claude Code is mid-session)
            if sessions[index].status == .ended {
                let reactivatingEvents: Set<HookEventType> = [
                    .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
                    .permissionRequest, .preCompact, .subagentStart
                ]
                if let eventType = event.eventType, reactivatingEvents.contains(eventType) {
                    sessions[index].status = .active
                    sessions[index].phase = (eventType == .preCompact) ? .compacting
                        : (eventType == .sessionStart) ? .idle : .running
                    clearSubagents(at: index)
                    sessions[index].idleUntil = nil
                } else {
                    // Truly stale event (e.g. Stop, SessionEnd) — count it but skip transitions
                    persist()
                    return
                }
            }

            // State machine transitions
            switch event.eventType {
            case .sessionStart:
                sessions[index].status = .active
                sessions[index].phase = .idle
                clearSubagents(at: index)
                if let pid = event.terminalPid {
                    sessions[index].terminalPid = pid
                    sessions[index].terminalBundleId = Self.resolveBundleId(pid: pid)
                }
                if let pid = event.shellPid {
                    sessions[index].shellPid = pid
                }

            case .userPromptSubmit:
                sessions[index].phase = .running
                clearIdleUntil(for: sessionId)

            case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest:
                // Tool activity confirms agent is working
                sessions[index].phase = .running

            case .preCompact:
                sessions[index].phase = .compacting

            case .postCompact:
                sessions[index].phase = .running

            case .stop, .stopFailure:
                sessions[index].phase = .idle
                clearSubagents(at: index)
                setIdleUntil(for: sessionId)
                shouldNotifyObservers = true
                PeachyLog.session.debug("Session idle (Stop): \(sessionId) idleUntil=+\(Int(self.idleRetentionDuration))s")

            case .sessionEnd:
                PeachyLog.session.info("Session ended (SessionEnd): \(sessionId)")
                sessions[index].status = .ended
                sessions[index].phase = .idle
                clearSubagents(at: index)
                shouldNotifyObservers = true

            case .subagentStart:
                sessions[index].phase = .running
                clearIdleUntil(for: sessionId)
                let previousCount = sessions[index].activeSubagentCount
                if let agentId = event.agentId {
                    reconciledSubagentStopIds[sessionId]?.remove(agentId)
                    var ids = activeSubagentIds[sessionId] ?? []
                    ids.insert(agentId)
                    activeSubagentIds[sessionId] = ids
                } else {
                    anonymousSubagentCounts[sessionId, default: 0] += 1
                }
                updateSubagentCount(at: index)
                shouldNotifyObservers = sessions[index].activeSubagentCount != previousCount

            case .subagentStop:
                let previousCount = sessions[index].activeSubagentCount
                // Prefer an exact identity match. If one side omitted agentId, consume one entry from
                // the opposite pool deterministically. Anonymous events cannot be duplicate-safe
                // because they carry no stable identity; identified duplicate starts remain idempotent.
                if let agentId = event.agentId {
                    if activeSubagentIds[sessionId]?.remove(agentId) != nil {
                        reconciledSubagentStopIds[sessionId, default: []].insert(agentId)
                    } else if !(reconciledSubagentStopIds[sessionId]?.contains(agentId) ?? false),
                       (anonymousSubagentCounts[sessionId] ?? 0) > 0 {
                        anonymousSubagentCounts[sessionId, default: 0] -= 1
                        reconciledSubagentStopIds[sessionId, default: []].insert(agentId)
                    }
                } else if (anonymousSubagentCounts[sessionId] ?? 0) > 0 {
                    anonymousSubagentCounts[sessionId, default: 0] -= 1
                } else if let agentId = activeSubagentIds[sessionId]?.sorted().first {
                    activeSubagentIds[sessionId]?.remove(agentId)
                    reconciledSubagentStopIds[sessionId, default: []].insert(agentId)
                }
                updateSubagentCount(at: index)
                shouldNotifyObservers = sessions[index].activeSubagentCount != previousCount

            default:
                break
            }
            if sessions[index].activeSubagentCount != previousSubagentCount {
                shouldNotifyObservers = true
            }
        } else {
            // New session
            let startsRunning = event.eventType == .userPromptSubmit || event.eventType == .subagentStart
            let phase: AgentSession.Phase = startsRunning ? .running : .idle
            var session = AgentSession(
                id: sessionId,
                projectDir: event.cwd,
                projectName: event.projectName,
                agentSource: AgentSource(rawSource: event.source),
                status: .active,
                phase: phase,
                eventCount: 1,
                startedAt: Date(),
                lastEventAt: Date()
            )
            session.terminalPid = event.terminalPid
            session.rawSource = event.source
            if let pid = event.terminalPid {
                session.terminalBundleId = Self.resolveBundleId(pid: pid)
            }
            session.shellPid = event.shellPid
            session.transcriptPath = event.transcriptPath
            if event.eventType == .subagentStart {
                if let agentId = event.agentId {
                    reconciledSubagentStopIds[sessionId]?.remove(agentId)
                    activeSubagentIds[sessionId] = [agentId]
                } else {
                    anonymousSubagentCounts[sessionId] = 1
                }
                session.activeSubagentCount = 1
                shouldNotifyObservers = true
            }
            PeachyLog.session.info("Session created: \(sessionId) project=\(session.projectName ?? "/") src=\(session.rawSource ?? "-")")
            sessions.insert(session, at: 0)
        }
        persist()
        if shouldNotifyObservers {
            onPhasesChanged?()
        }
    }

    private static func resolveBundleId(pid: Int) -> String? {
        NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }
}
