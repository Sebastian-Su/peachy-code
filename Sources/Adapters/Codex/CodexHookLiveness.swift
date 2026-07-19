import Foundation

/// Tracks which Codex sessions have delivered real hook events.
/// When a session has live hooks, the log-polling fallback (CodexSessionMonitor)
/// must stay silent for that session to avoid duplicate bubbles / feed entries.
@MainActor
final class CodexHookLiveness {
    static let shared = CodexHookLiveness()

    private var liveSessions: Set<String> = []

    func markLive(sessionId: String) {
        liveSessions.insert(sessionId)
    }

    func isLive(sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return liveSessions.contains(sessionId)
    }

    func clear(sessionId: String) {
        liveSessions.remove(sessionId)
    }
}
