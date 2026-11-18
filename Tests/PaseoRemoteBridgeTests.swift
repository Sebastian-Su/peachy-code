import XCTest
@testable import PeachyPet

final class PaseoRemoteBridgeTests: XCTestCase {
    private func turn(provider: String = "codex", status: String = "idle",
                      lastMessage: String? = "All checks passed.") -> PaseoRemoteBridge.TurnEnded {
        PaseoRemoteBridge.TurnEnded(serverId: "srv_mini", host: "MacMini", agentId: "a1", provider: provider,
                                    title: "Merge regression", cwd: "/Users/someone/project", status: status,
                                    lastMessage: lastMessage)
    }

    func testDecodesBridgeLines() throws {
        let line = #"{"type":"turn_ended","serverId":"srv_mini","host":"MacMini","agentId":"a1","provider":"codex","title":"Merge regression","cwd":"/Users/someone/project","status":"idle","lastMessage":"All checks passed."}"#
        XCTAssertEqual(PaseoRemoteBridge.decode(line: Data(line.utf8)), .turnEnded(turn()))

        let hosts = #"{"type":"hosts","hosts":[{"label":"Win 360","status":"online","watching":true}]}"#
        XCTAssertEqual(PaseoRemoteBridge.decode(line: Data(hosts.utf8)),
                       .hosts([.init(label: "Win 360", status: "online", watching: true)]))
        XCTAssertEqual(PaseoRemoteBridge.decode(line: Data(#"{"type":"connected","serverId":"srv"}"#.utf8)), .connected)
        XCTAssertNil(PaseoRemoteBridge.decode(line: Data("not json".utf8)))
    }

    func testRemoteTurnBecomesStopOfItsEngine() {
        let codex = PaseoRemoteBridge.event(for: turn())
        XCTAssertEqual(codex.eventType, .stop)
        XCTAssertEqual(codex.agentSource, .codex)
        XCTAssertEqual(codex.sessionId, "paseo-remote-a1")
        XCTAssertEqual(codex.originator, "MacMini")
        XCTAssertEqual(codex.projectName, "project")
        XCTAssertEqual(codex.lastAssistantMessage, "All checks passed.")

        XCTAssertEqual(PaseoRemoteBridge.event(for: turn(provider: "claude")).agentSource, .claudeCode)
        XCTAssertEqual(PaseoRemoteBridge.event(for: turn(provider: "claude/anthropic/opus")).agentSource, .claudeCode)
        XCTAssertEqual(PaseoRemoteBridge.event(for: turn(status: "error")).eventType, .stopFailure)
    }

    func testRemoteSessionShowsItsHostAndHasNoLocalFocusTarget() {
        let store = SessionStore()
        for provider in ["codex", "claude"] {
            let event = PaseoRemoteBridge.event(for: turn(provider: provider))
            store.recordEvent(event)
            let session = store.sessions.first { $0.id == event.sessionId }
            XCTAssertEqual(session?.host, .other(originator: "MacMini"), provider)
            XCTAssertEqual(session?.phase, .idle, provider)
        }
    }

    @MainActor
    func testRemoteResultIsAlwaysShownInThePanel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PeachyPetPaseoRemote-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tool = directory.appendingPathComponent("tool")
        try "#!/bin/bash\ncat > /dev/null\nprintf '全部检查通过。'\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)

        let plugin = SessionResultPlugin(defaults: defaults)
        plugin.save(.init(backend: .executable, executablePath: tool.path, destination: .agent), for: .codex)
        let delivered = expectation(description: "result delivered")
        var received: (SessionResultReport, SessionResultPlugin.Destination)?
        plugin.onResult = { report, destination in
            received = (report, destination)
            delivered.fulfill()
        }

        let event = PaseoRemoteBridge.event(for: turn())
        XCTAssertTrue(SessionResultPlugin.accepts(event))
        // A remote session has no pending Stop hook to continue, so nothing is returned to it.
        XCTAssertNil(plugin.receive(event, allowsContinuation: false))
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(received?.1, .panel)
        XCTAssertEqual(received?.0.markdown, "全部检查通过。")
    }
}
