import Foundation
import Network

/// Wraps an NWConnection held open by the Codex hook script (hook-sender.sh --source codex-cli).
/// Codex PermissionRequest hooks block on curl until we return a decision — same model as
/// HookConnectionTransport. First version supports allow/deny only.
final class CodexHookTransport: ResponseTransport {
    private let connection: NWConnection

    var capabilities: Set<ResponseCapability> {
        [.permissionResponse]
    }

    var isAlive: Bool {
        switch connection.state {
        case .ready, .preparing, .setup:
            return true
        default:
            return false
        }
    }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func sendDecision(_ decision: PermissionDecision) {
        let (status, body, exitHint) = decision.httpResponse
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nX-Exit-Code: \(exitHint)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // Codex first version does not support these; capabilities excludes them so UI never calls them.
    func sendAllowWithUpdatedInput(_ updatedInput: [String: Any]) {
        sendDecision(.allow)
    }

    func sendAllowWithUpdatedPermissions(_ permissions: [[String: Any]]) {
        sendDecision(.allow)
    }

    func cancel() {
        connection.cancel()
    }

    func onRemoteClose(_ handler: @escaping () -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                DispatchQueue.main.async { handler() }
            default:
                break
            }
        }
        monitorReceive(handler)
    }

    // MARK: - Private

    private func monitorReceive(_ handler: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                DispatchQueue.main.async { handler() }
            } else {
                self?.monitorReceive(handler)
            }
        }
    }
}
