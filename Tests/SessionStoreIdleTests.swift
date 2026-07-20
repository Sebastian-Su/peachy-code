import XCTest
@testable import PeachyPet

@MainActor
final class SessionStoreIdleTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(idleRetention: TimeInterval = 300) -> SessionStore {
        SessionStore(idleRetentionDuration: idleRetention)
    }

    private func event(
        type: HookEventType,
        sessionId: String,
        taskId: String? = nil,
        source: String = "codex-cli"
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: type.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            source: source,
            taskId: taskId
        )
    }

    // MARK: - Idle retention

    func testStopSetsIdleUntil() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "idle-\(UUID().uuidString)"

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(type: .stop, sessionId: sid))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertNotNil(session?.idleUntil, "stop must set idleUntil")
        XCTAssertGreaterThan(session!.idleUntil!, Date(), "idleUntil must be in the future")
    }

    func testIdleSessionExpires() {
        let store = makeStore(idleRetention: 0) // zero retention = immediate expiry
        defer { store.stopTimers() }
        let sid = "idle-expire-\(UUID().uuidString)"

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(type: .stop, sessionId: sid))
        // Manually trigger expiry
        store.expireIdleSessions()

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.status, .ended, "zero-retention idle session must be ended after expiry")
    }

    func testNewActivityReactivatesIdleSession() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "idle-reactivate-\(UUID().uuidString)"

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(type: .stop, sessionId: sid))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.phase, .idle)

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .running, "new userPromptSubmit must resume running")
        XCTAssertNil(session?.idleUntil, "idleUntil must be cleared on reactivation")
    }

    // MARK: - Internal turn snapshot & rollback

    func testPureInternalTurnDeletesTempSession() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "rollback-new-\(UUID().uuidString)"
        let taskId = "t-internal"

        // EventProcessor always calls saveSnapshot before recordEvent for userPromptSubmit with taskId
        store.saveSnapshot(taskId: taskId, sessionId: sid)
        // No prior session — internal turn creates a temp one
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid, taskId: taskId))
        XCTAssertNotNil(store.sessions.first(where: { $0.id == sid }), "temp session created")

        store.rollbackInternalTurn(taskId: taskId, sessionId: sid)
        XCTAssertNil(store.sessions.first(where: { $0.id == sid }),
                     "temp session must be deleted after rollback")
    }

    func testInternalTurnRestoresOuterRunningSession() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "rollback-outer-\(UUID().uuidString)"
        let outerTaskId = "t-outer"
        let innerTaskId = "t-inner"

        // Outer turn starts
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid, taskId: outerTaskId))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.phase, .running)

        // Inner (internal) turn — snapshot saved before recordEvent in EventProcessor
        store.saveSnapshot(taskId: innerTaskId, sessionId: sid)
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid, taskId: innerTaskId))

        // Internal result rolls back
        store.rollbackInternalTurn(taskId: innerTaskId, sessionId: sid)
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.phase, .running,
                       "outer session phase must be restored to running")
    }

    func testInternalTurnRestoresOuterIdleWithIdleUntil() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "rollback-idle-\(UUID().uuidString)"
        let innerTaskId = "t-inner-idle"

        // Outer turn is idle after a stop
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(type: .stop, sessionId: sid))
        let originalIdleUntil = store.sessions.first(where: { $0.id == sid })?.idleUntil
        XCTAssertNotNil(originalIdleUntil)

        // Inner (internal) turn arrives while outer is idle
        store.saveSnapshot(taskId: innerTaskId, sessionId: sid)
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid, taskId: innerTaskId))

        // Internal result rolls back — outer session should return to idle with original idleUntil
        store.rollbackInternalTurn(taskId: innerTaskId, sessionId: sid)
        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(session?.idleUntil, originalIdleUntil,
                       "idleUntil must be restored to pre-inner-turn value")
    }

    func testRealStopDiscardsSnapshot() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "discard-snapshot-\(UUID().uuidString)"
        let taskId = "t-discard"

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid, taskId: taskId))
        store.saveSnapshot(taskId: taskId, sessionId: sid)
        store.discardSnapshot(taskId: taskId)
        store.recordEvent(event(type: .stop, sessionId: sid, taskId: taskId))

        // After discarding snapshot, stop must go through normally
        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertNotNil(session?.idleUntil, "real stop must set idleUntil even after snapshot was discarded")
    }

    // MARK: - Startup migration

    func testStartupMigratesIdleSessionWithPastIdleUntil() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        // Inject a session that is active+idle with idleUntil in the past
        let sid = "migrate-past-\(UUID().uuidString)"
        var session = AgentSession(
            id: sid,
            projectDir: "/tmp",
            projectName: "test",
            agentSource: .codex,
            status: .active,
            phase: .idle,
            eventCount: 1,
            startedAt: Date(timeIntervalSinceNow: -600),
            lastEventAt: Date(timeIntervalSinceNow: -600)
        )
        session.idleUntil = Date(timeIntervalSinceNow: -1) // already expired
        store.injectSessionForTesting(session)
        store.runStartupMigration()

        let result = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(result?.status, .ended, "past-idleUntil session must be ended on startup migration")
    }
}
