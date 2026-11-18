import Foundation
import Network

@Observable
final class LocalServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var port: UInt16
    private let usesEphemeralPort: Bool
    private var stopped = false

    var onEventReceived: ((AgentEvent) -> Void)?
    var onSessionResult: (@MainActor (AgentEvent) -> Task<String?, Never>?)?
    var onPermissionRequest: ((AgentEvent, NWConnection) -> Void)?
    /// Custom input endpoint: `POST /input {"name":"x","value":true}`
    var onInputReceived: ((String, ConditionValue) -> Void)?
    /// Install mascot endpoint: `POST /install {config JSON}`
    var onInstallReceived: ((PeachyAnimationConfig) -> Void)?

    private var retryCount = 0
    private static let maxRetries = 3
    /// Max ports to try before giving up (49152..49161)
    private static let maxPortAttempts: UInt16 = 10

    init(port: UInt16 = Constants.serverPort) {
        self.port = port
        usesEphemeralPort = port == 0
    }

    func start() throws {
        stopped = false
        // Cancel any existing listener before creating a new one
        listener?.cancel()
        listener = nil

        let params = NWParameters.tcp
        // Enable SO_REUSEADDR so we can rebind immediately after a crash/restart
        // (avoids TIME_WAIT blocking the port for up to 60s)
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        listener = try NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.retryCount = 0
                    // If we landed on a different port than default, persist it and reinstall hooks
                    if self.usesEphemeralPort {
                        self.port = self.listener?.port?.rawValue ?? 0
                    } else if self.port != Constants.serverPort {
                        Constants.setServerPort(self.port)
                        try? HookInstaller.install()
                    }
                    print("[PeachyPet] Server listening on port \(self.port)")
                case .failed(let error):
                    self.isRunning = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.tryNextPort(reason: "failed", error: error)
                case .waiting(let error):
                    // .waiting means the port is unavailable (e.g. held by rapportd
                    // or in TIME_WAIT after a crash). Try the next port.
                    self.isRunning = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.tryNextPort(reason: "waiting", error: error)
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    /// Try the next port in the range. If all ports exhausted, retry with backoff.
    private func tryNextPort(reason: String, error: NWError) {
        guard !stopped, !usesEphemeralPort else { return }
        let nextPort = port + 1
        if nextPort < Constants.defaultServerPort + Self.maxPortAttempts {
            print("[PeachyPet] Port \(port) \(reason): \(error) - trying \(nextPort)...")
            port = nextPort
            try? start()
        } else {
            // All ports exhausted, retry from default with backoff
            guard retryCount < Self.maxRetries else {
                print("[PeachyPet] Server gave up after trying ports \(Constants.defaultServerPort)-\(port) x\(Self.maxRetries)")
                return
            }
            retryCount += 1
            port = Constants.defaultServerPort
            let delay = min(Double(2 << retryCount), 30.0)
            print("[PeachyPet] All ports busy - retry \(retryCount)/\(Self.maxRetries) in \(Int(delay))s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped else { return }
                try? self.start()
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        var receivedData = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data {
                    receivedData.append(data)
                }

                // Process as soon as we have a complete HTTP request (headers + body),
                // OR when the connection closes / errors.
                // This avoids a deadlock where curl keeps the connection open waiting
                // for a response (e.g. PermissionRequest with --max-time 120) but
                // the server never processes the request because isComplete is false.
                if self?.hasCompleteHTTPRequest(receivedData) == true || isComplete || error != nil {
                    self?.processRequest(receivedData, connection: connection)
                } else {
                    readMore()
                }
            }
        }

        readMore()
    }

    /// Check if we have a complete HTTP request (headers + full body per Content-Length).
    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        // A receive boundary can split a multibyte character, or leave the
        // headers in their own packet. Compare the declared length in bytes.
        guard let separator = data.range(of: Data([13, 10, 13, 10])) else { return false }
        let headers = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1)
            guard field.count == 2, field[0].caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            guard let length = Int(field[1].trimmingCharacters(in: .whitespaces)), length >= 0 else { return false }
            return data.distance(from: separator.upperBound, to: data.endIndex) >= length
        }
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        guard let httpString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        // Extract first line to get method + path
        let firstLine = httpString.components(separatedBy: "\r\n").first ?? ""

        // Route: GET /health — quick liveness check for hook script
        if firstLine.contains("GET /health") {
            sendResponse(connection: connection, status: "200 OK", body: "ok")
            return
        }

        // CORS preflight for browser requests (e.g. from masko.ai export modal)
        if firstLine.contains("OPTIONS /install") {
            sendCORSResponse(connection: connection, status: "204 No Content", body: "")
            return
        }

        // Extract body for POST routes
        guard let bodyRange = httpString.range(of: "\r\n\r\n") else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "No body")
            return
        }
        let bodyString = String(httpString[bodyRange.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid body")
            return
        }

        // Route: POST /hook — receive Claude Code hook events
        if firstLine.contains("POST /hook") {
            let acceptsStopResponse = Self.acceptsStopResponse(from: connection.endpoint,
                                                              headers: httpString[..<bodyRange.lowerBound])
            let decoder = JSONDecoder()
            if let event = try? decoder.decode(AgentEvent.self, from: bodyData) {
                print("[PeachyPet] Hook received: \(event.hookEventName)")

                // PermissionRequest: hold connection open for user decision
                if event.eventType == .permissionRequest, let handler = onPermissionRequest {
                    DispatchQueue.main.async {
                        handler(event, connection)
                    }
                    // Do NOT send response — connection stays open until user decides
                    // Also forward to event processor for tracking
                    DispatchQueue.main.async { [weak self] in
                        self?.onEventReceived?(event)
                    }
                    return
                }

                if acceptsStopResponse, event.eventType == .stop {
                    Task { @MainActor [self] in
                        // Copilot registers this Stop specifically for the result plugin.
                        if event.agentSource != .copilot { onEventReceived?(event) }
                        let response = await onSessionResult?(event)?.value
                        sendResponse(connection: connection, status: "200 OK", body: response ?? "")
                    }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onEventReceived?(event)
                }
            } else {
                print("[PeachyPet] Hook received but failed to decode JSON")
            }
            sendResponse(connection: connection, status: "200 OK", body: "OK")
            return
        }

        // Route: POST /input — set a custom input on the state machine
        // Body: {"name":"myVar","value":true} or {"name":"myVar","value":42}
        if firstLine.contains("POST /input") {
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let name = json["name"] as? String {
                let conditionValue: ConditionValue
                if let b = json["value"] as? Bool {
                    conditionValue = .bool(b)
                } else if let n = json["value"] as? Double {
                    conditionValue = .number(n)
                } else if let n = json["value"] as? Int {
                    conditionValue = .number(Double(n))
                } else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "value must be bool or number")
                    return
                }
                print("[PeachyPet] Input received: \(name) = \(json["value"] ?? "nil")")
                DispatchQueue.main.async { [weak self] in
                    self?.onInputReceived?(name, conditionValue)
                }
                sendResponse(connection: connection, status: "200 OK", body: "OK")
            } else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "Expected {\"name\":\"...\",\"value\":...}")
            }
            return
        }

        // Route: POST /install — receive mascot config from masko.ai export modal
        if firstLine.contains("POST /install") {
            let decoder = JSONDecoder()
            if let config = try? decoder.decode(PeachyAnimationConfig.self, from: bodyData) {
                print("[PeachyPet] Install received: \(config.name)")
                DispatchQueue.main.async { [weak self] in
                    self?.onInstallReceived?(config)
                }
                sendCORSResponse(connection: connection, status: "200 OK", body: "OK")
            } else {
                sendCORSResponse(connection: connection, status: "400 Bad Request", body: "Invalid config JSON")
            }
            return
        }

        sendResponse(connection: connection, status: "404 Not Found", body: "Not Found")
    }

    /// The existing event endpoint also receives non-command traffic. Only the
    /// local hook sender can start result processing or receive a continuation.
    static func acceptsStopResponse(from endpoint: NWEndpoint, headers: Substring) -> Bool {
        guard case let .hostPort(host, _) = endpoint,
              host == .ipv4(.loopback) || host == .ipv6(.loopback) else { return false }
        let lines = headers.components(separatedBy: "\r\n")
        return lines.first == "POST /hook HTTP/1.1"
            && lines.contains { $0.caseInsensitiveCompare("X-Peachy-Stop: 1") == .orderedSame }
            && lines.contains { $0.caseInsensitiveCompare("Content-Type: application/json") == .orderedSame }
    }

    private func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Send response with CORS headers (for browser requests from masko.ai)
    private func sendCORSResponse(connection: NWConnection, status: String, body: String) {
        let headers = [
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
        ].joined(separator: "\r\n")
        let response = "HTTP/1.1 \(status)\r\n\(headers)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Restart the server on a new port. Updates Constants, reinstalls hooks, and restarts.
    func restart(port newPort: UInt16) {
        stop()
        Constants.setServerPort(newPort)
        port = newPort
        retryCount = 0
        // Reinstall hooks so the hook script uses the new port
        try? HookInstaller.install()
        try? start()
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    deinit {
        listener?.cancel()
    }
}
