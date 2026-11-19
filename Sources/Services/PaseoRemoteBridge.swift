import Foundation

/// Turn completions from agents on hosts connected to the local Paseo daemon. A bundled Node
/// script (tools/paseo-bridge) uses Paseo's official SDK and prints one JSON message per line;
/// this class runs it and turns each completed turn into a Stop event. Local agents are not
/// reported: their hooks already reach PeachyPet directly.
@Observable
final class PaseoRemoteBridge {
    struct Host: Decodable, Equatable {
        let label: String
        let status: String
        let watching: Bool
    }

    struct RemoteTurn: Decodable, Equatable {
        let serverId: String
        let host: String
        let agentId: String
        let provider: String
        let title: String?
        let cwd: String?
        let status: String
        let lastMessage: String?
    }

    enum Message: Equatable {
        case connected
        case disconnected
        case hosts([Host])
        case turnStarted(RemoteTurn)
        case turnEnded(RemoteTurn)
    }

    enum Status: Equatable {
        case off
        case starting
        /// The local daemon is unreachable; the bridge keeps retrying.
        case waitingForDaemon
        case connected(hosts: [Host])
        case nodeMissing
        case bridgeMissing
        case exited(Int32)
    }

    private(set) var status: Status = .off
    var onRemoteTurn: ((RemoteTurn) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var lineBuffer = Data()

    static let clientSuffix = "-paseo"

    // MARK: - Messages

    static func decode(line: Data) -> Message? {
        struct Envelope: Decodable {
            let type: String
            let hosts: [Host]?
        }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: line) else { return nil }
        switch envelope.type {
        case "connected": return .connected
        case "disconnected": return .disconnected
        case "hosts": return .hosts(envelope.hosts ?? [])
        case "turn_started": return (try? decoder.decode(RemoteTurn.self, from: line)).map(Message.turnStarted)
        case "turn_ended": return (try? decoder.decode(RemoteTurn.self, from: line)).map(Message.turnEnded)
        default: return nil
        }
    }

    /// The event a remote turn produces: a prompt when it starts, a Stop when it ends. The
    /// client tag keeps the engine ("codex", "claude") so it reads like that agent's own event.
    static func event(for turn: RemoteTurn) -> AgentEvent {
        let engine = turn.provider.split(separator: "/").first.map(String.init) ?? turn.provider
        let hook: HookEventType = switch turn.status {
        case "running": .userPromptSubmit // a turn began; shows the session as running
        case "error": .stopFailure
        default: .stop
        }
        return AgentEvent(
            hookEventName: hook.rawValue,
            sessionId: "paseo-remote-\(turn.agentId)",
            cwd: turn.cwd,
            lastAssistantMessage: turn.lastMessage,
            client: engine + clientSuffix,
            originator: turn.host
        )
    }

    /// Opens the agent on its own host through the local Paseo app.
    static func host(for turn: RemoteTurn) -> SessionHost {
        .paseo(agentId: turn.agentId, serverId: turn.serverId)
    }

    /// A remote session reads "host • title" wherever a session is named.
    static func metadata(for turn: RemoteTurn, sessionId: String) -> SessionMetadataUpdate {
        SessionMetadataUpdate(sessionId: sessionId, sessionTitle: turn.title, firstUserPrompt: nil,
                              projectDisplayName: turn.host)
    }

    // MARK: - Process

    func start() {
        guard process == nil else { return }
        status = .starting
        guard let script = Bundle.main.url(forResource: "paseo-bridge", withExtension: "mjs", subdirectory: "PaseoBridge") else {
            status = .bridgeMissing
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let node = Self.locateNode()
            DispatchQueue.main.async {
                guard let self, self.status == .starting else { return }
                guard let node else {
                    self.status = .nodeMissing
                    return
                }
                self.launch(node: node, script: script)
            }
        }
    }

    func stop() {
        let running = process
        process = nil
        running?.terminate()
        lineBuffer.removeAll()
        status = .off
    }

    private func launch(node: URL, script: URL) {
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        // The bridge exits when its stdin closes, so it cannot outlive a crashed app.
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data, from: process) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            if !text.isEmpty { PeachyLog.network.info("paseo-bridge: \(text, privacy: .public)") }
        }
        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.status = .exited(finished.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            PeachyLog.network.error("paseo-bridge failed to start: \(error.localizedDescription, privacy: .public)")
            status = .exited(-1)
        }
    }

    private func receive(_ data: Data, from source: Process) {
        guard source === process else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let message = Self.decode(line: Data(line)) else { continue }
            switch message {
            case .connected: status = .connected(hosts: [])
            case .disconnected: status = .waitingForDaemon
            case .hosts(let hosts): status = .connected(hosts: hosts)
            case .turnStarted(let turn), .turnEnded(let turn): onRemoteTurn?(turn)
            }
        }
    }

    /// An app launched from Finder has no shell PATH, so check the usual install locations
    /// first and then ask a login shell, which also covers version managers.
    static func locateNode(fileManager: FileManager = .default) -> URL? {
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v node"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard shell.terminationStatus == 0, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
