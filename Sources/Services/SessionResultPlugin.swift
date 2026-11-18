import Foundation

@Observable
final class SessionResultPlugin {
    enum Conversation: String, CaseIterable, Hashable, Codable {
        case new, reuse
    }

    enum Destination: String, CaseIterable, Hashable, Codable {
        case panel, agent
    }

    struct Configuration: Codable, Equatable {
        var isEnabled = true
        var backend: SessionResultTool.Backend = .codex
        var executablePath = ""
        var instructions = ""
        var conversation: Conversation = .new
        var destination: Destination = .panel
        var triggerKeyword = ""

        func matches(_ report: String) -> Bool {
            let keyword = triggerKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return keyword.isEmpty || report.range(of: keyword, options: .caseInsensitive) != nil
        }
    }

    private static let configurationsKey = "sessionResult.agentConfigurations"
    private static let supportedAgents: [AgentSource] = [.claudeCode, .codex, .copilot]
    private(set) var lastErrors: [AgentSource: String] = [:]
    private var configurations: [String: Configuration]

    var onResult: ((SessionResultReport, Destination) async -> Void)?

    private let defaults: UserDefaults
    @ObservationIgnored private var pending: [String: Task<String?, Never>] = [:]
    private var workerSessions: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workerSessions = defaults.dictionary(forKey: "sessionResult.workerSessions") as? [String: String] ?? [:]

        if let stored = defaults.data(forKey: Self.configurationsKey) {
            configurations = (try? JSONDecoder().decode([String: Configuration].self, from: stored)) ?? [:]
        } else if let legacy = Self.legacyConfiguration(in: defaults) {
            // Copy the previous global behavior to each agent once. Keep the legacy
            // keys so rolling back the application still restores its configuration.
            configurations = Dictionary(uniqueKeysWithValues: Self.supportedAgents.map { ($0.rawValue, legacy) })
            defaults.set(try? JSONEncoder().encode(configurations), forKey: Self.configurationsKey)
        } else {
            configurations = [:]
        }
    }

    func configuration(for agent: AgentSource) -> Configuration? {
        configurations[agent.rawValue]
    }

    @MainActor func save(_ configuration: Configuration, for agent: AgentSource) {
        guard Self.supportedAgents.contains(agent) else { return }
        var saved = configurations
        saved[agent.rawValue] = configuration
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.configurationsKey)
        configurations = saved
        lastErrors[agent] = nil
    }

    private static func legacyConfiguration(in defaults: UserDefaults) -> Configuration? {
        let prefix = "sessionResult."
        let fields = ["enabled", "backend", "executablePath", "instructions", "conversation", "destination"]
        guard fields.contains(where: { defaults.object(forKey: prefix + $0) != nil }) else { return nil }
        return Configuration(
            isEnabled: defaults.bool(forKey: prefix + "enabled"),
            backend: defaults.string(forKey: prefix + "backend").flatMap(SessionResultTool.Backend.init) ?? .codex,
            executablePath: defaults.string(forKey: prefix + "executablePath") ?? "",
            instructions: defaults.string(forKey: prefix + "instructions") ?? "",
            conversation: defaults.string(forKey: prefix + "conversation").flatMap(Conversation.init) ?? .new,
            destination: defaults.string(forKey: prefix + "destination").flatMap(Destination.init) ?? .panel
        )
    }

    /// Returns nil for panel delivery so the caller can acknowledge the Stop
    /// immediately. A continuation task stays attached to the requesting hook.
    /// Without a hook to continue (a remote Paseo session), the result goes to the panel.
    @MainActor func receive(_ event: AgentEvent, allowsContinuation: Bool = true) -> Task<String?, Never>? {
        let agent = event.agentSource
        guard let configuration = configuration(for: agent), configuration.isEnabled,
              Self.accepts(event), let sessionID = event.sessionId else { return nil }

        let tool = SessionResultTool(backend: configuration.backend, executablePath: configuration.executablePath,
                                     workingDirectory: SessionResultTool.defaultWorkingDirectory)
        let conversation = configuration.conversation
        let destination = allowsContinuation ? configuration.destination : .panel
        let key = [event.agentSource.rawValue, sessionID, tool.backend.rawValue, tool.executablePath].joined(separator: ":")
        let previous = pending[key]
        // Keep requests for a resumed conversation in order, even when two
        // completion hooks from the same source arrive during one model turn.
        let task = Task { @MainActor [weak self] () -> String? in
            _ = await previous?.value
            guard let self else { return nil }
            do {
                guard let original = try await SessionResultTranscript.report(for: event),
                      configuration.matches(original) else { return nil }
                let targetSession = conversation == .reuse
                    ? self.workerSessions[key] ?? (tool.backend == .executable ? UUID().uuidString : nil)
                    : nil
                let output = try await tool.run(prompt: Self.prompt(instructions: configuration.instructions, report: original),
                                                sessionID: targetSession, retainSession: conversation == .reuse)
                if conversation == .reuse {
                    guard let id = output.sessionID else { throw SessionResultTool.Failure.missingSessionID }
                    self.workerSessions[key] = id
                    self.defaults.set(self.workerSessions, forKey: "sessionResult.workerSessions")
                }
                self.lastErrors[agent] = nil
                let report = SessionResultReport(sessionID: sessionID, agent: event.agentSource,
                                                 project: event.projectName, markdown: output.markdown)
                await self.onResult?(report, destination)
                if destination == .agent { return Self.continuation(for: report.markdown) }
            } catch {
                self.lastErrors[agent] = Self.errorMessage(error)
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
