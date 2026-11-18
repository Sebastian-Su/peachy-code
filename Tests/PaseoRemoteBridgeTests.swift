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

    func testRemoteSessionShowsHostThenTitleAndOpensInPaseo() throws {
        let store = SessionStore()
        for provider in ["codex", "claude"] {
            let remote = turn(provider: provider)
            let event = PaseoRemoteBridge.event(for: remote)
            let sessionId = try XCTUnwrap(event.sessionId)
            store.recordEvent(event)
            store.assignHost(PaseoRemoteBridge.host(for: remote), toSession: sessionId)
            store.updateMetadata(PaseoRemoteBridge.metadata(for: remote, sessionId: sessionId))
            // A later turn of the same agent must not demote the host.
            store.recordEvent(event)

            let session = try XCTUnwrap(store.sessions.first { $0.id == sessionId })
            XCTAssertEqual(session.host, .paseo(agentId: "a1", serverId: "srv_mini"), provider)
            XCTAssertEqual(session.displayProjectName, "MacMini", provider)
            XCTAssertEqual(session.displaySessionTitle, "Merge regression", provider)
            XCTAssertEqual(session.focusAppBundleId, PaseoRegistry.bundleId, provider)
            XCTAssertEqual(SessionRoute(session: session).destination, .paseo, provider)

            var opened: URL?
            IDETerminalFocus.focusSession(session, urlOpener: { opened = $0; return true })
            XCTAssertEqual(opened?.absoluteString, "paseo://h/srv_mini/agent/a1", provider)
        }
    }

    @MainActor
    func testRemoteHostIsAppliedBeforeTheCompletionIsAnnounced() async throws {
        let events = EventStore(); events.clear()
        let sessions = SessionStore()
        defer { sessions.stopTimers() }
        let notifications = NotificationStore()
        let processor = EventProcessor(eventStore: events, sessionStore: sessions,
                                       notificationStore: notifications, notificationService: .shared)
        let remote = turn()
        let event = PaseoRemoteBridge.event(for: remote)
        let sessionId = try XCTUnwrap(event.sessionId)
        var announcedEarly: Bool?
        await processor.process(event) {
            announcedEarly = notifications.notifications.contains { $0.sessionId == sessionId }
            sessions.assignHost(PaseoRemoteBridge.host(for: remote), toSession: sessionId)
        }
        XCTAssertEqual(announcedEarly, false)
        XCTAssertTrue(notifications.notifications.contains { $0.sessionId == sessionId })
        XCTAssertEqual(sessions.sessions.first { $0.id == sessionId }?.host, PaseoRemoteBridge.host(for: remote))
    }

    func testLocalPaseoHostSavedBeforeRemoteHostsStillDecodes() throws {
        let saved = Data(#"{"paseo":{"agentId":"a1"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SessionHost.self, from: saved), .paseo(agentId: "a1"))
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
