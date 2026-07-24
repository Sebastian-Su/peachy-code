import Foundation

// MARK: - Public metadata types

struct SessionTitleMetadata: Equatable {
    let sessionId: String
    let title: String?
}

struct SessionProjectMetadata: Equatable {
    let sessionId: String
    let projectName: String?
}

struct SessionMetadataUpdate: Equatable {
    let sessionId: String
    let sessionTitle: String?
    let firstUserPrompt: String?
    let projectDisplayName: String?
}

// MARK: - Pure Claude transcript parser

enum ClaudeTranscriptParser {

    /// Returns the last `custom-title` matching `sessionId`, or nil.
    static func parseTitle(lines: [String], sessionId: String) -> String? {
        var result: String? = nil
        for line in lines {
            guard let obj = jsonObject(line),
                  (obj["type"] as? String) == "custom-title",
                  (obj["sessionId"] as? String) == sessionId,
                  let title = obj["customTitle"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            result = title
        }
        return result
    }

    /// Returns the first non-empty user message text across all lines (no sessionId filter needed —
    /// Claude transcripts are per-session files).
    static func parseFirstPrompt(lines: [String]) -> String? {
        for line in lines {
            guard let obj = jsonObject(line),
                  (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any],
                  (message["role"] as? String) == "user",
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for part in content {
                guard (part["type"] as? String) == "text",
                      let text = part["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - Pure Codex session_index parser

enum CodexSessionIndexParser {

    /// Returns the `thread_name` of the last record whose `id` equals `sessionId`.
    static func parseThreadName(lines: [String], sessionId: String) -> String? {
        var result: String? = nil
        for line in lines {
            guard let obj = jsonObject(line),
                  (obj["id"] as? String) == sessionId,
                  let name = obj["thread_name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            result = name
        }
        return result
    }
}

// MARK: - Pure Codex global state parser

enum CodexGlobalStateParser {

    /// Resolves the project display name for `sessionId` from the Codex global-state JSON string.
    /// Returns nil on any malformed / missing data — never converts absence to an empty string.
    static func parseProjectName(json: String, sessionId: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        guard let assignments = root["thread-project-assignments"] as? [String: Any],
              let entry = assignments[sessionId] as? [String: Any],
              let projectId = entry["projectId"] as? String,
              !projectId.isEmpty
        else { return nil }

        guard let projects = root["local-projects"] as? [String: Any],
              let project = projects[projectId] as? [String: Any],
              let name = project["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return name
    }
}

// MARK: - Private shared helper

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

// MARK: - SessionMetadataMonitor

/// Polls provider metadata files every `pollInterval` seconds for active sessions
/// and emits `SessionMetadataUpdate` whenever a value changes.
///
/// - Thread safety: must be used exclusively on the main thread / main actor.
/// - Scope: only sessions supplied via `start(activeSessions:)` / `update(activeSessions:)`.
final class SessionMetadataMonitor {

    // MARK: Configuration

    private let homeDirectory: String
    private let pollInterval: TimeInterval
    private let onUpdate: (SessionMetadataUpdate) -> Void

    // MARK: State

    private var activeSessions: [AgentSession] = []

    // Per-path read offset for incremental JSONL polling
    private var transcriptOffsets: [String: UInt64] = [:]   // transcriptPath -> offset
    private var transcriptInodes: [String: UInt64] = [:]    // transcriptPath -> inode (detect atomic replacement)
    private var sessionIndexOffset: UInt64 = 0
    private var sessionIndexInode: UInt64 = 0

    // First-prompt tracking (only set once per sessionId)
    private var firstUserPrompts: [String: String] = [:]

    // Last-seen title / project per sessionId (to suppress no-change emits)
    private var lastEmittedTitle: [String: String] = [:]
    private var lastEmittedProject: [String: String] = [:]

    // Global state mtime
    private var lastGlobalStateMtime: Date? = nil

    // Timer
    private var timer: Timer?

    // MARK: Derived paths

    private var codexDir: String {
        (homeDirectory as NSString).appendingPathComponent(".codex")
    }

    private var sessionIndexPath: String {
        (codexDir as NSString).appendingPathComponent("session_index.jsonl")
    }

    private var globalStatePath: String {
        (codexDir as NSString).appendingPathComponent(".codex-global-state.json")
    }

    // MARK: Init

    init(
        homeDirectory: String = NSHomeDirectory(),
        pollInterval: TimeInterval = 1.0,
        onUpdate: @escaping (SessionMetadataUpdate) -> Void
    ) {
        self.homeDirectory = homeDirectory
        self.pollInterval = pollInterval
        self.onUpdate = onUpdate
    }

    // MARK: Lifecycle

    /// Start the monitor with the initial set of active sessions.
    /// Performs an immediate full scan from byte zero, then schedules polling.
    func start(activeSessions: [AgentSession]) {
        self.activeSessions = activeSessions
        // Full initial scan from byte zero
        scanAll(fromZero: true)
        scheduleTimer()
    }

    /// Update the active session list without resetting offsets.
    func update(activeSessions: [AgentSession]) {
        self.activeSessions = activeSessions
    }

    /// Stop polling and clear all state.
    func stop() {
        timer?.invalidate()
        timer = nil
        transcriptOffsets.removeAll()
        transcriptInodes.removeAll()
        sessionIndexOffset = 0
        sessionIndexInode = 0
        lastGlobalStateMtime = nil
        firstUserPrompts.removeAll()
        lastEmittedTitle.removeAll()
        lastEmittedProject.removeAll()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.scanAll(fromZero: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Scanning

    private func scanAll(fromZero: Bool) {
        if fromZero {
            transcriptOffsets.removeAll()
            transcriptInodes.removeAll()
            sessionIndexOffset = 0
            sessionIndexInode = 0
            lastGlobalStateMtime = nil
        }

        // 1. Transcript files for Claude sessions
        for session in activeSessions {
            guard let path = session.transcriptPath else { continue }
            scanTranscript(path: path, sessionId: session.id, fromZero: fromZero)
        }

        // 2. Codex session_index (covers all Codex sessions)
        scanSessionIndex(fromZero: fromZero)

        // 3. Global state (mtime-gated)
        scanGlobalState()
    }

    // MARK: Transcript scanning

    private func scanTranscript(path: String, sessionId: String, fromZero: Bool) {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64
        else { return }

        let currentInode = attrs[.systemFileNumber] as? UInt64 ?? 0
        var offset: UInt64 = fromZero ? 0 : (transcriptOffsets[path] ?? 0)

        // Detect atomic replacement (new inode) or truncation (size shrank)
        let knownInode = transcriptInodes[path] ?? 0
        if currentInode != knownInode || fileSize < offset {
            offset = 0
        }
        transcriptInodes[path] = currentInode

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        let newData = handle.readDataToEndOfFile()
        let newOffset = offset + UInt64(newData.count)
        transcriptOffsets[path] = newOffset

        guard !newData.isEmpty,
              let chunk = String(data: newData, encoding: .utf8)
        else { return }

        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Parse custom-title from this chunk
        // "last wins" within the full file requires reading all lines every time we reset;
        // for incremental append we keep the last seen title from prior scans.
        if offset == 0 {
            // Full file re-read: parse all lines for definitive last title
            if let title = ClaudeTranscriptParser.parseTitle(lines: lines, sessionId: sessionId) {
                emitIfChanged(sessionId: sessionId, title: title, project: nil)
            }
        } else {
            // Incremental: any new custom-title in this chunk is the latest
            if let title = ClaudeTranscriptParser.parseTitle(lines: lines, sessionId: sessionId) {
                emitIfChanged(sessionId: sessionId, title: title, project: nil)
            }
        }

        // Parse first user prompt (only stored once)
        if firstUserPrompts[sessionId] == nil {
            // For accuracy, when offset==0 we have all lines; otherwise scan new lines only.
            if let prompt = ClaudeTranscriptParser.parseFirstPrompt(lines: lines) {
                firstUserPrompts[sessionId] = prompt
                emitFirstPrompt(sessionId: sessionId, prompt: prompt)
            }
        }
    }

    // MARK: Codex session_index scanning

    private func scanSessionIndex(fromZero: Bool) {
        let path = sessionIndexPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64
        else { return }

        var offset: UInt64 = fromZero ? 0 : sessionIndexOffset

        // Detect atomic replacement (new inode) or truncation
        let currentInode = attrs[.systemFileNumber] as? UInt64 ?? 0
        if currentInode != sessionIndexInode || fileSize < offset {
            offset = 0
        }
        sessionIndexInode = currentInode

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        let newData = handle.readDataToEndOfFile()
        sessionIndexOffset = offset + UInt64(newData.count)

        guard !newData.isEmpty,
              let chunk = String(data: newData, encoding: .utf8)
        else { return }

        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
        let activeIds = Set(activeSessions.map(\.id))

        for sessionId in activeIds {
            if let name = CodexSessionIndexParser.parseThreadName(lines: lines, sessionId: sessionId) {
                emitIfChanged(sessionId: sessionId, title: name, project: nil)
            }
        }
    }

    // MARK: Global state scanning

    private func scanGlobalState() {
        let path = globalStatePath
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else { return }

        // Only re-read if mtime changed (or first scan)
        if let last = lastGlobalStateMtime, last == mtime { return }
        lastGlobalStateMtime = mtime

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let activeIds = Set(activeSessions.map(\.id))
        for sessionId in activeIds {
            if let projectName = CodexGlobalStateParser.parseProjectName(json: content, sessionId: sessionId) {
                emitIfChanged(sessionId: sessionId, title: nil, project: projectName)
            }
        }
    }

    // MARK: - Emit helpers

    private func emitIfChanged(sessionId: String, title: String?, project: String?) {
        var changedTitle: String? = nil
        var changedProject: String? = nil

        if let t = title, lastEmittedTitle[sessionId] != t {
            lastEmittedTitle[sessionId] = t
            changedTitle = t
        }
        if let p = project, lastEmittedProject[sessionId] != p {
            lastEmittedProject[sessionId] = p
            changedProject = p
        }

        guard changedTitle != nil || changedProject != nil else { return }

        let update = SessionMetadataUpdate(
            sessionId: sessionId,
            sessionTitle: changedTitle,
            firstUserPrompt: nil,
            projectDisplayName: changedProject
        )
        onUpdate(update)
    }

    private func emitFirstPrompt(sessionId: String, prompt: String) {
        let update = SessionMetadataUpdate(
            sessionId: sessionId,
            sessionTitle: nil,
            firstUserPrompt: prompt,
            projectDisplayName: nil
        )
        onUpdate(update)
    }
}
