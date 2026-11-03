import Foundation

/// "Where it came from, where a click goes": the engine that runs a session and
/// the app the jump button focuses. Built from the same facts as
/// `AgentSession.focusAppBundleId`, so the drawn route and the jump agree.
struct SessionRoute: Equatable {
    enum Destination: Equatable {
        case terminal
        case codexDesktop
        case paseo
        case other(String)
        case unknown
    }

    let engine: AgentSource
    let destination: Destination
    let destinationBundleId: String?

    init(session: AgentSession) {
        engine = session.agentSource
        destinationBundleId = session.focusAppBundleId
        switch session.host {
        case .terminal: destination = .terminal
        case .codexDesktop: destination = .codexDesktop
        case .paseo: destination = .paseo
        case .other(let originator): destination = .other(originator)
        case .unknown: destination = .unknown
        }
    }

    /// `other` hosts have no focus target; clicking does nothing, so the button is disabled.
    var canJump: Bool {
        if case .other = destination { return false }
        return true
    }
}
