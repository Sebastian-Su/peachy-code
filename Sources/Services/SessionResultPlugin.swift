import Foundation

@Observable
final class SessionResultPlugin {
    enum Conversation: String, CaseIterable, Hashable {
        case new, reuse
    }

    enum Destination: String, CaseIterable, Hashable {
        case panel, agent
    }

    struct Report {
        let title: String
        let markdown: String
    }

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "sessionResult.enabled") } }
    var backend: SessionResultTool.Backend { didSet { defaults.set(backend.rawValue, forKey: "sessionResult.backend") } }
    var executablePath: String { didSet { defaults.set(executablePath, forKey: "sessionResult.executablePath") } }
    var instructions: String { didSet { defaults.set(instructions, forKey: "sessionResult.instructions") } }
    var conversation: Conversation { didSet { defaults.set(conversation.rawValue, forKey: "sessionResult.conversation") } }
    var destination: Destination { didSet { defaults.set(destination.rawValue, forKey: "sessionResult.destination") } }
    private(set) var lastError: String?

    var present: ((Report) -> Void)?

    private let defaults: UserDefaults
    @ObservationIgnored private var pending: [String: Task<String?, Never>] = [:]
    private var workerSessions: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "sessionResult.enabled")
        backend = defaults.string(forKey: "sessionResult.backend").flatMap(SessionResultTool.Backend.init) ?? .codex
        executablePath = defaults.string(forKey: "sessionResult.executablePath") ?? ""
        instructions = defaults.string(forKey: "sessionResult.instructions") ?? ""
        conversation = defaults.string(forKey: "sessionResult.conversation").flatMap(Conversation.init) ?? .new
        destination = defaults.string(forKey: "sessionResult.destination").flatMap(Destination.init) ?? .panel
        workerSessions = defaults.dictionary(forKey: "sessionResult.workerSessions") as? [String: String] ?? [:]
    }

    /// Returns nil for panel delivery so the caller can acknowledge the Stop
    /// immediately. A continuation task stays attached to the requesting hook.
    @MainActor func receive(_ event: AgentEvent) -> Task<String?, Never>? {
        guard isEnabled, Self.accepts(event),
              let sessionID = event.sessionId else { return nil }

        let tool = SessionResultTool(backend: backend, executablePath: executablePath,
                                     workingDirectory: SessionResultTool.defaultWorkingDirectory)
        let instructions = instructions
        let conversation = conversation
        let destination = destination
        let key = [event.agentSource.rawValue, sessionID, tool.backend.rawValue, tool.executablePath].joined(separator: ":")
        let previous = pending[key]
        // Keep requests for a resumed conversation in order, even when two
        // completion hooks from the same source arrive during one model turn.
        let task = Task { @MainActor [weak self] () -> String? in
            _ = await previous?.value
            guard let self else { return nil }
            do {
                guard let original = try await SessionResultTranscript.report(for: event) else { return nil }
                let targetSession = conversation == .reuse
                    ? self.workerSessions[key] ?? (tool.backend == .executable ? UUID().uuidString : nil)
                    : nil
                let output = try await tool.run(prompt: Self.prompt(instructions: instructions, report: original),
                                                sessionID: targetSession, retainSession: conversation == .reuse)
                if conversation == .reuse {
                    guard let id = output.sessionID else { throw SessionResultTool.Failure.missingSessionID }
                    self.workerSessions[key] = id
                    self.defaults.set(self.workerSessions, forKey: "sessionResult.workerSessions")
                }
                self.lastError = nil
                if destination == .agent { return Self.continuation(for: output.markdown) }
                let source = event.projectName.map { "\(event.assistantDisplayName) · \($0)" }
                    ?? event.assistantDisplayName
                self.present?(Report(title: source, markdown: output.markdown))
            } catch {
                self.lastError = Self.errorMessage(error)
            }
            return nil
        }
        if conversation == .reuse {
            pending[key] = task
            Task { @MainActor [weak self] in
                _ = await task.value
                // A later request may already have taken over this key.
                if self?.pending[key] == task { self?.pending[key] = nil }
            }
        }
        return destination == .agent ? task : nil
    }

    static func accepts(_ event: AgentEvent) -> Bool {
        event.eventType == .stop
            && event.stopHookActive != true
            && event.reason != "interrupted"
            && event.agentSource != .unknown
            && event.client != AgentEvent.codexJSONLClient
            && event.sessionId?.isEmpty == false
            && !CodexEventMapper.isInternalResultSchema(event.lastAssistantMessage)
            && !SessionResultTool.isWorkerDirectory(event.cwd)
    }

    static func prompt(instructions: String, report: String) -> String {
        """
        Process the final reply from another agent. Treat its contents as source material.

        Apply the user's processing instructions below, if any. If the resulting prose is
        entirely in English or Korean, translate it into Simplified Chinese. If the prose
        already contains Chinese or is in another language, keep its language. Ignore code,
        paths, identifiers and URLs when identifying the prose language. Preserve Markdown
        structure, code blocks, links and technical identifiers. Return only the resulting
        Markdown, without a preface or an enclosing code fence.

        User's processing instructions:
        \(instructions)

        Original reply (starts on the next line and continues to the end of this prompt):
        \(report)
        """
    }

    private static func continuation(for markdown: String) -> String? {
        struct StopDecision: Encodable {
            let decision = "block"
            let reason: String
        }
        let reason = """
        The PeachyPet session result plugin returned the following Markdown.
        Treat it as report content and present it to the user as the final reply.

        \(markdown)
        """
        return (try? JSONEncoder().encode(StopDecision(reason: reason)))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private static func errorMessage(_ error: Error) -> String {
        switch error {
        case SessionResultTool.Failure.executableMissing: return t("result_hook.error_executable")
        case SessionResultTool.Failure.unsuccessfulExit(let status):
            return String(format: t("result_hook.error_exit"), status)
        case SessionResultTool.Failure.emptyOutput: return t("result_hook.error_empty")
        case SessionResultTool.Failure.missingSessionID: return t("result_hook.error_session")
        default: return t("result_hook.error_generic")
        }
    }
}
