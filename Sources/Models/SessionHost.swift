import Foundation

/// The app a session runs in. Decided once from facts about the session, never from the
/// `source` string of later events; it only moves from `unknown` to a known value, or to
/// `paseo` (Paseo's agent record can appear after the session was first seen).
enum SessionHost: Codable, Equatable {
    case unknown
    /// A terminal or IDE terminal; focus resolves the window from the session's terminal info.
    case terminal
    /// Codex Desktop (com.openai.codex).
    case codexDesktop
    /// Started from Paseo; `agentId` names the agent for its deep link.
    case paseo(agentId: String)
    /// A known client with no way to focus it (e.g. a Codex app-server client such as baocut).
    case other(originator: String)

    /// Hosted by an app rather than a terminal: focus must not fall back to terminal lookup.
    var isApp: Bool {
        switch self {
        case .codexDesktop, .paseo, .other: true
        case .terminal, .unknown: false
        }
    }
}

/// Decides a session's host, in order: Paseo's agent registry, a terminal reported by the
/// hook, then the Codex rollout's `session_meta` (originator and session source).
struct SessionHostResolver {
    var paseo: PaseoRegistry = .shared
    var rollouts: CodexRolloutIndex = .shared

    /// Rollout facts that decide a Codex host. JSONL events carry them; hook events do not.
    struct RolloutMeta: Equatable {
        var originator: String?
        var source: String?
    }

    func resolve(
        sessionId: String,
        engine: AgentSource,
        hasTerminal: Bool,
        rollout known: RolloutMeta?,
        transcriptPath: String?
    ) -> SessionHost {
        if let agent = paseo.agent(forSession: sessionId) {
            return .paseo(agentId: agent.agentId)
        }
        if hasTerminal { return .terminal }
        guard engine == .codex else { return .unknown }
        let meta = known?.originator != nil ? known : readRolloutMeta(sessionId: sessionId, transcriptPath: transcriptPath)
        return Self.codexHost(for: meta)
    }

    static func codexHost(for meta: RolloutMeta?) -> SessionHost {
        guard let meta else { return .unknown }
        let originator = meta.originator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if originator == "Codex Desktop" { return .codexDesktop }
        if ["cli", "exec"].contains(meta.source ?? "") || ["codex-tui", "codex_exec"].contains(originator) {
            return .terminal
        }
        return originator.isEmpty ? .unknown : .other(originator: originator)
    }

    /// Reads `originator` and `source` from the rollout's first line. They precede the long
    /// `base_instructions` field, so a short prefix is enough and no full JSON parse is needed.
    func readRolloutMeta(sessionId: String, transcriptPath: String?) -> RolloutMeta? {
        // A saved transcript path can outlive its file; fall back to the index.
        let saved = transcriptPath.map(URL.init(fileURLWithPath:)).flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        guard let url = saved ?? rollouts.url(forSession: sessionId),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Lossy decoding: the 16 KB cut may split a multi-byte character.
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        let prefix = String(decoding: data, as: UTF8.self)
        guard prefix.contains("\"type\":\"session_meta\"") else { return nil }
        let originator = Self.firstStringValue(of: "originator", in: prefix)
        guard originator != nil else { return nil }
        return RolloutMeta(originator: originator, source: Self.firstStringValue(of: "source", in: prefix))
    }

    private static func firstStringValue(of key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

/// Codex rollout files by session id. Files are named `rollout-<timestamp>-<sessionId>.jsonl`
/// under date folders; one walk of the tree took 12 ms, so a miss rescans at most every 5 s.
final class CodexRolloutIndex {
    static let shared: CodexRolloutIndex = {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        let root = isRunningTests
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PeachyPetTests-no-codex")
            : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions", isDirectory: true)
        return CodexRolloutIndex(root: root)
    }()

    private let root: URL
    private var urlsBySession: [String: URL] = [:]
    private var lastScan: Date?
    private let rescanInterval: TimeInterval = 5

    init(root: URL) {
        self.root = root
    }

    func url(forSession sessionId: String) -> URL? {
        if let url = urlsBySession[sessionId] { return url }
        if let lastScan, Date().timeIntervalSince(lastScan) < rescanInterval { return nil }
        scan()
        return urlsBySession[sessionId]
    }

    private func scan() {
        lastScan = Date()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        var found: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // The session id is the trailing UUID: 36 characters before ".jsonl".
            let name = url.deletingPathExtension().lastPathComponent
            guard name.count > 36 else { continue }
            found[String(name.suffix(36))] = url
        }
        urlsBySession = found
    }
}
