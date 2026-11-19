import XCTest
@testable import PeachyPet

@MainActor
final class AppStoreWaitingInputTests: XCTestCase {
    private func makeActiveSession(id: String, phase: AgentSession.Phase) -> AgentSession {
        AgentSession(
            id: id,
            projectDir: "/tmp",
            projectName: "openclaw360",
            agentSource: .claudeCode,
            status: .active,
            phase: phase,
            eventCount: 2,
            startedAt: Date(),
            lastEventAt: Date()
        )
    }

    func testIdlePromptPresentsWaitingToastForActiveWaitingSession() {
        let app = AppStore()
        defer { app.sessionStore.stopTimers() }
        let previous = UserDefaults.standard.object(forKey: SessionFinishedStore.enabledKey)
        UserDefaults.standard.set(true, forKey: SessionFinishedStore.enabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SessionFinishedStore.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SessionFinishedStore.enabledKey)
            }
        }
        let sid = "app-waiting-\(UUID().uuidString)"
        app.sessionStore.injectSessionForTesting(makeActiveSession(id: sid, phase: .waitingInput))

        app.updateSessionToast(for: AgentEvent(
            hookEventName: HookEventType.notification.rawValue,
            sessionId: sid,
            cwd: "/tmp",
            notificationType: "idle_prompt"
        ))

        XCTAssertEqual(app.sessionFinishedStore.current?.kind, .waitingInput)
        XCTAssertEqual(app.sessionFinishedStore.current?.sessionId, sid)
        app.sessionFinishedStore.dismiss()
    }

    func testIdlePromptDoesNotPresentToastForEndedSession() {
        let app = AppStore()
        defer { app.sessionStore.stopTimers() }
        let previous = UserDefaults.standard.object(forKey: SessionFinishedStore.enabledKey)
        UserDefaults.standard.set(true, forKey: SessionFinishedStore.enabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SessionFinishedStore.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SessionFinishedStore.enabledKey)
            }
        }
        let sid = "app-ended-\(UUID().uuidString)"
        var session = makeActiveSession(id: sid, phase: .idle)
        session.status = .ended
        app.sessionStore.injectSessionForTesting(session)

        app.updateSessionToast(for: AgentEvent(
            hookEventName: HookEventType.notification.rawValue,
            sessionId: sid,
            cwd: "/tmp",
            notificationType: "idle_prompt"
        ))

        XCTAssertNil(app.sessionFinishedStore.current)
    }

    func testResumeActivityDismissesWaitingToast() {
        let app = AppStore()
        defer { app.sessionStore.stopTimers() }
        let previous = UserDefaults.standard.object(forKey: SessionFinishedStore.enabledKey)
        UserDefaults.standard.set(true, forKey: SessionFinishedStore.enabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SessionFinishedStore.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SessionFinishedStore.enabledKey)
            }
        }
        let sid = "app-resume-\(UUID().uuidString)"
        app.sessionStore.injectSessionForTesting(makeActiveSession(id: sid, phase: .waitingInput))
        app.updateSessionToast(for: AgentEvent(
            hookEventName: HookEventType.notification.rawValue,
            sessionId: sid,
            cwd: "/tmp",
            notificationType: "idle_prompt"
        ))
        XCTAssertEqual(app.sessionFinishedStore.current?.kind, .waitingInput)

        // Tool activity (not UserPromptSubmit) resumes the session to running.
        app.sessionStore.recordEvent(AgentEvent(
            hookEventName: HookEventType.preToolUse.rawValue,
            sessionId: sid,
            cwd: "/tmp"
        ))
        app.updateSessionToast(for: AgentEvent(
            hookEventName: HookEventType.preToolUse.rawValue,
            sessionId: sid,
            cwd: "/tmp"
        ))

        XCTAssertNil(app.sessionFinishedStore.current)
    }

    func testAnyUserPromptDismissesGlobalCompletedToast() {
        let app = AppStore()
        defer { app.sessionStore.stopTimers() }
        let previous = UserDefaults.standard.object(forKey: SessionFinishedStore.enabledKey)
        UserDefaults.standard.set(true, forKey: SessionFinishedStore.enabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SessionFinishedStore.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SessionFinishedStore.enabledKey)
            }
        }
        app.sessionFinishedStore.show(
            kind: .completed,
            sessionId: "session-a",
            projectName: "openclaw360"
        )

        app.updateSessionToast(for: AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: "session-b",
            cwd: "/tmp"
        ))

        XCTAssertNil(app.sessionFinishedStore.current)
    }
}

@MainActor
final class AppStoreRemoteToastTests: XCTestCase {
    func testRemoteCompletionNamesHostAndSessionAndOnlyItsOwnStartDismissesIt() {
        let app = AppStore()
        defer { app.sessionStore.stopTimers() }
        let previous = UserDefaults.standard.object(forKey: SessionFinishedStore.enabledKey)
        UserDefaults.standard.set(true, forKey: SessionFinishedStore.enabledKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SessionFinishedStore.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SessionFinishedStore.enabledKey)
            }
            app.sessionFinishedStore.dismiss()
        }
        let local = "local-\(UUID().uuidString)"
        app.sessionStore.injectSessionForTesting(AgentSession(
            id: local, projectDir: "/tmp/masko-code", projectName: "masko-code", agentSource: .codex,
            status: .active, phase: .idle, eventCount: 1, startedAt: Date(), lastEventAt: Date()))
        app.updateSessionToast(for: AgentEvent(hookEventName: "Stop", sessionId: local, client: "codex-cli"))
        XCTAssertEqual(app.sessionFinishedStore.current?.projectName, "masko-code")
        XCTAssertEqual(app.sessionFinishedStore.current?.isRemote, false)

        // Another host starting a turn leaves the local card alone.
        let turn = PaseoRemoteBridge.RemoteTurn(serverId: "srv_us", host: "Mac US", agentId: "a9", provider: "claude",
                                                title: "提测", cwd: "/Users/u/namiwork-desktop", status: "running",
                                                lastMessage: nil)
        let start = PaseoRemoteBridge.event(for: turn)
        let sessionId = start.sessionId!
        app.sessionStore.recordEvent(start)
        app.sessionStore.assignHost(PaseoRemoteBridge.host(for: turn), toSession: sessionId)
        app.sessionStore.updateMetadata(PaseoRemoteBridge.metadata(for: turn, sessionId: sessionId))
        app.updateSessionToast(for: start)
        XCTAssertEqual(app.sessionFinishedStore.current?.sessionId, local)

        app.sessionFinishedStore.dismiss()
        let end = PaseoRemoteBridge.event(for: PaseoRemoteBridge.RemoteTurn(
            serverId: "srv_us", host: "Mac US", agentId: "a9", provider: "claude", title: "提测",
            cwd: "/Users/u/namiwork-desktop", status: "idle", lastMessage: "done"))
        app.sessionStore.recordEvent(end)
        app.updateSessionToast(for: end)
        XCTAssertEqual(app.sessionFinishedStore.current?.projectName, "Mac US · 提测")
        XCTAssertEqual(app.sessionFinishedStore.current?.isRemote, true)
    }
}
