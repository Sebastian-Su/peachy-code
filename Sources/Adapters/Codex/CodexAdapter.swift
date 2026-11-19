import Foundation

/// Codex adapter - tails local Codex session logs and routes mapped events into the shared pipeline.
final class CodexAdapter: AgentAdapter {
    let source: AgentSource = .codex
    let monitor = CodexSessionMonitor(queue: DispatchQueue(label: "PeachyPet.CodexSessionMonitor", qos: .utility))

    var isRunning: Bool { monitor.isRunning }

    var onEvent: ((AgentEvent) -> Void)?
    var onPermissionRequest: ((AgentEvent, ResponseTransport) -> Void)?
    var onInput: ((String, ConditionValue) -> Void)?

    func isAvailable() -> Bool {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return true
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return true
        }
        return FileManager.default.fileExists(atPath: CodexSessionMonitor.defaultSessionsRoot.path)
    }

    func isRegistered() -> Bool {
        CodexHookInstaller.isRegistered()
    }

    func install() throws {
        try CodexHookInstaller.install()
    }

    func uninstall() {
        try? CodexHookInstaller.uninstall()
    }

    func start() throws {
        monitor.onEventReceived = { [weak self] event in
            // FIFO: events must reach the session layer in log order.
            DispatchQueue.main.async {
                guard let self else { return }
                // 该会话已有真 hooks → 轮询事件全部静默，避免重复
                if CodexHookLiveness.shared.isLive(sessionId: event.sessionId) { return }
                self.route(event)
            }
        }
        // Log reads and parsing stay off the main thread; events hop to it above.
        let monitor = monitor
        monitor.queue.async { monitor.start() }
    }

    func stop() {
        let monitor = monitor
        monitor.queue.sync { monitor.stop() }
    }

    func route(_ event: AgentEvent) {
        guard !SessionResultTool.isWorkerDirectory(event.cwd), !shouldSuppress(event) else { return }

        if event.eventType == .permissionRequest {
            onPermissionRequest?(event, TerminalFallbackTransport(event: event))
        }

        onEvent?(event)
    }

    private func shouldSuppress(_ event: AgentEvent) -> Bool {
        guard let eventType = event.eventType else { return false }

        // Codex "question turns" use stop/task-complete markers while still waiting on user input.
        if eventType == .stop, event.isLikelyCodexQuestionPrompt {
            return true
        }
        if eventType == .taskCompleted, AgentEvent.looksLikeQuestionPrompt(event.taskSubject) {
            return true
        }

        return false
    }
}
