import Foundation

/// Per-engine summary for the Agents page: install status, session counts and
/// where those sessions ran.
struct AgentOverview: Equatable, Identifiable {
    enum HostKind: Equatable, CaseIterable {
        case paseo, codexDesktop, terminal, other, unknown

        init(_ host: SessionHost) {
            switch host {
            case .paseo: self = .paseo
            case .codexDesktop: self = .codexDesktop
            case .terminal: self = .terminal
            case .other: self = .other
            case .unknown: self = .unknown
            }
        }
    }

    struct HostCount: Equatable {
        let kind: HostKind
        let count: Int
    }

    let engine: AgentSource
    let isInstalled: Bool
    let sessionCount: Int
    let activeCount: Int
    /// Non-zero hosts, in `HostKind` order.
    let hosts: [HostCount]

    var id: AgentSource { engine }

    static let engines: [AgentSource] = [.claudeCode, .codex, .copilot]

    static func build(sessions: [AgentSession], installed: [AgentSource: Bool]) -> [AgentOverview] {
        engines.map { engine in
            let own = sessions.filter { $0.agentSource == engine }
            let hosts = HostKind.allCases.compactMap { kind -> HostCount? in
                let count = own.filter { HostKind($0.host) == kind }.count
                return count > 0 ? HostCount(kind: kind, count: count) : nil
            }
            return AgentOverview(
                engine: engine,
                isInstalled: installed[engine] ?? false,
                sessionCount: own.count,
                activeCount: own.filter { $0.status == .active }.count,
                hosts: hosts
            )
        }
    }

    /// Reads each agent's hook/plugin registration. Read-only: never installs or rewrites config.
    static func readInstallStatus() -> [AgentSource: Bool] {
        [
            .claudeCode: HookInstaller.isRegistered(),
            .codex: CodexHookInstaller.isRegistered(),
            .copilot: CopilotCLIInstaller.isRegistered(),
        ]
    }
}
