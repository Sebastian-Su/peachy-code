import AppKit
import SwiftUI
import XCTest
@testable import PeachyPet

final class SessionResultHookTests: XCTestCase {
    func testHookTransportsLargeMarkdownWithoutPassingItAsAnArgument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hook = directory.appendingPathComponent("hook.sh")
        try HookInstaller.scriptContentForTesting().write(to: hook, atomically: true, encoding: .utf8)

        let curl = directory.appendingPathComponent("curl")
        try """
        #!/bin/bash
        case "$*" in
            */health*) exit 0 ;;
        esac
        while [ "$#" -gt 1 ]; do
            case "$1" in
                --data-binary) [ "$2" = "@-" ] || exit 2; cat > "$TEST_CAPTURE"; exit ;;
                -d) printf '%s' "$2" > "$TEST_CAPTURE"; exit ;;
            esac
            shift
        done
        exit 2
        """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: curl.path)

        let markdown = String(repeating: "# Report\n- 한국어 / English / 中文\n", count: 80_000)
        let input = directory.appendingPathComponent("input")
        let capture = directory.appendingPathComponent("capture")
        let payload: [String: String] = [
            "hook_event_name": "Stop",
            "session_id": "test-session",
            "last_assistant_message": markdown,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hook.path]
        process.environment = [
            "PATH": "\(directory.path):/usr/bin:/bin",
            "TEST_CAPTURE": capture.path,
        ]
        let stdin = try FileHandle(forReadingFrom: input)
        defer { try? stdin.close() }
        process.standardInput = stdin
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(contentsOf: capture))
        XCTAssertTrue(event.lastAssistantMessage == markdown)
    }
}

extension SessionResultHookTests {
    @MainActor
    func testDefaultPanelDeliversLocalToolOutputAndPreservesPrompt() async throws {
        let (plugin, directory, cleanup) = try makePlugin()
        defer { cleanup() }
        XCTAssertFalse(plugin.isEnabled)
        XCTAssertEqual(plugin.destination, .panel)
        XCTAssertEqual(plugin.conversation, .new)
        plugin.isEnabled = true
        plugin.instructions = "Keep the headings."

        let output = expectation(description: "Markdown panel receives the report")
        plugin.onResult = { report, destination in
            XCTAssertEqual(destination, .panel)
            XCTAssertEqual(report.source.label, "Claude Code · sample-project")
            XCTAssertEqual(report.source.sessionID, "test-source")
            XCTAssertEqual(report.markdown, "# 中文报告\n\n- 已完成\n")
            output.fulfill()
        }
        XCTAssertNil(plugin.receive(completedReply()))
        await fulfillment(of: [output], timeout: 5)

        let captured = try String(contentsOf: directory.appendingPathComponent("input"), encoding: .utf8)
        XCTAssertTrue(captured.contains("Keep the headings."))
        XCTAssertTrue(captured.contains("English or Korean"))
        XCTAssertTrue(captured.hasSuffix("# Original report\n\n- Done."))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("ids"), encoding: .utf8), "new\n")
    }

    @MainActor
    func testStopHTTPReturnsMarkdownToRequestingAgentAndContinuesOnlyOnce() async throws {
        let (plugin, directory, cleanup) = try makePlugin()
        defer { cleanup() }
        plugin.isEnabled = true
        plugin.destination = .agent
        plugin.onResult = { report, destination in
            XCTAssertEqual(destination, .agent)
            XCTAssertEqual(report.source.sessionID, "test-source")
        }

        let server = LocalServer(port: 0)
        server.onSessionResult = { plugin.receive($0) }
        try server.start()
        defer { server.stop() }
        for _ in 0..<50 where !server.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(server.isRunning)
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/hook"))
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Peachy-Stop")
        let report = String(repeating: "### 회의 보고서 中文\n", count: 12_000)
        request.httpBody = try JSONEncoder().encode(
            AgentEvent(hookEventName: "Stop", sessionId: "test-source", lastAssistantMessage: report, client: "codex-cli")
        )
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decision = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(decision["decision"], "block")
        XCTAssertTrue(decision["reason"]?.hasSuffix("# 中文报告\n\n- 已完成\n") == true)
        let captured = try String(contentsOf: directory.appendingPathComponent("input"), encoding: .utf8)
        XCTAssertTrue(captured.hasSuffix(report))

        request.httpBody = try JSONEncoder().encode(completedReply(client: "codex-cli", continuation: true))
        let (continued, _) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(continued.isEmpty)

        request.setValue(nil, forHTTPHeaderField: "X-Peachy-Stop")
        request.httpBody = try JSONEncoder().encode(completedReply(client: "codex-cli"))
        let (eventOnly, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(String(decoding: eventOnly, as: UTF8.self), "OK")
    }

    @MainActor
    func testReusableWorkerSessionIsScopedToTheTriggeringSession() async throws {
        let (plugin, directory, cleanup) = try makePlugin()
        defer { cleanup() }
        plugin.isEnabled = true
        plugin.destination = .agent
        plugin.conversation = .reuse
        let first = try XCTUnwrap(plugin.receive(completedReply()))
        let second = try XCTUnwrap(plugin.receive(completedReply()))
        let another = try XCTUnwrap(plugin.receive(completedReply(id: "another-source")))
        let firstOutput = await first.value
        let secondOutput = await second.value
        let anotherOutput = await another.value
        XCTAssertNotNil(firstOutput)
        XCTAssertNotNil(secondOutput)
        XCTAssertNotNil(anotherOutput)

        let ids = try String(contentsOf: directory.appendingPathComponent("ids"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertTrue(ids.allSatisfy { UUID(uuidString: String($0)) != nil })
    }

    func testCopilotReadsOnlyLastTurnAndPreservesFullMarkdown() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("events.jsonl")
        func record(_ type: String, _ data: [String: Any] = [:]) throws -> Data {
            var result = try JSONSerialization.data(withJSONObject: ["type": type, "data": data])
            result.append(10)
            return result
        }
        var contents = try record("assistant.message", ["content": "Previous turn"])
        contents.append(try record("user.message"))
        contents.append(try record("assistant.message", ["content": "Working", "toolRequests": ["tool"]]))
        try contents.write(to: transcript)
        XCTAssertNil(try SessionResultTranscript.latestCopilotReply(at: transcript))

        let markdown = String(repeating: "## 한국어\n", count: 35_000)
        contents.append(try record("assistant.message", ["content": markdown, "toolRequests": []]))
        contents.append(try record("assistant.turn_end"))
        try contents.write(to: transcript)
        XCTAssertTrue(try SessionResultTranscript.latestCopilotReply(at: transcript) == markdown)
    }

    func testNonfinalInternalAndWorkerEventsAreIgnored() {
        XCTAssertTrue(SessionResultPlugin.accepts(completedReply(client: "codex-cli")))
        XCTAssertFalse(SessionResultPlugin.accepts(completedReply(client: AgentEvent.codexJSONLClient)))
        XCTAssertFalse(SessionResultPlugin.accepts(completedReply(continuation: true)))
        XCTAssertFalse(SessionResultPlugin.accepts(AgentEvent(hookEventName: "Stop", sessionId: "source",
                                                               lastAssistantMessage: "{\"outcome\":\"allow\"}")))
        XCTAssertFalse(SessionResultPlugin.accepts(AgentEvent(hookEventName: "Stop", sessionId: "source",
                                                               cwd: SessionResultTool.defaultWorkingDirectory.path)))
        XCTAssertFalse(SessionResultPlugin.accepts(AgentEvent(hookEventName: "StopFailure", sessionId: "source")))
    }

    @MainActor
    func testResultUsesTheExistingNativeHUD() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionResultStore(databaseURL: directory.appendingPathComponent("results.sqlite3"))
        let report = SessionResultReport(sessionID: "native-source", agent: .claudeCode,
                                         project: "Native", markdown: "# 中文\n\n- **通过**")
        await store.add(report, showPreview: true)

        let config = PermissionHUDConfig()
        let manager = GlobalHotkeyManager()
        let sessions = SessionStore()
        defer { sessions.stopTimers() }
        sessions.recordEvent(AgentEvent(hookEventName: "SessionStart", sessionId: "native-source",
                                        cwd: "/tmp/native-fixture", terminalPid: Int(getpid())))
        let view = PermissionHUDView(config: config, sessionResults: store)
            .environment(PendingPermissionStore())
            .environment(manager)
            .environment(SessionSwitcherStore())
            .environment(sessions)
            .environment(SessionFinishedStore())
        let panel = OverlayPanel(contentRect: NSRect(x: 100, y: 100, width: 280, height: 200))
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(store.preview?.report, report)
        XCTAssertGreaterThan(host.fittingSize.height, 30)
        XCTAssertNotNil(store.preview?.deadline)
        XCTAssertEqual(report.source.focusTarget(in: sessions.sessions)?.id, "native-source")
        manager.activeCard = .result
        manager.isCmdHeld = true
        for _ in 0..<20 where store.preview?.deadline != nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(store.preview?.deadline, "Cmd shown by the result view pauses the timer")
        manager.activeCard = .permission
        for _ in 0..<20 where store.preview?.deadline == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(store.preview?.deadline, "Permission takes keyboard ownership and resumes the timer")
        store.dismissPreview()
        XCTAssertNil(store.preview)
        XCTAssertEqual(store.entries.first?.sessionID, "native-source")
    }

    private func completedReply(id: String = "test-source", client: String? = nil, continuation: Bool = false) -> AgentEvent {
        AgentEvent(hookEventName: "Stop", sessionId: id, cwd: "/tmp/sample-project",
                   stopHookActive: continuation, lastAssistantMessage: "# Original report\n\n- Done.", client: client)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @MainActor
    private func makePlugin() throws -> (SessionResultPlugin, URL, () -> Void) {
        let directory = try temporaryDirectory()
        let suite = "PeachyPetSessionResult-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tool = directory.appendingPathComponent("tool")
        try """
        #!/bin/bash
        cat > "\(directory.path)/input"
        printf '%s\\n' "${PEACHYPET_SESSION_ID:-new}" >> "\(directory.path)/ids"
        printf '# 中文报告\\n\\n- 已完成\\n'
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let plugin = SessionResultPlugin(defaults: defaults)
        plugin.backend = .executable
        plugin.executablePath = tool.path
        return (plugin, directory, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }
}
