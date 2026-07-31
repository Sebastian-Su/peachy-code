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
