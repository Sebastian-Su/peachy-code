import XCTest
@testable import PeachyPet

@MainActor
final class SessionStoreIdleTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(idleRetention: TimeInterval = 300) -> SessionStore {
        let store = SessionStore(idleRetentionDuration: idleRetention)
        store.autoHideInactiveSessions = true
        return store
    }

    private func event(
        type: HookEventType,
        sessionId: String,
        taskId: String? = nil,
        source: String = "codex-cli",
        notificationType: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: type.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            notificationType: notificationType,
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

    func testGenericCodexStopDoesNotDowngradeDesktopSessionIdentity() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "desktop-source-\(UUID().uuidString)"

        store.recordEvent(event(type: .sessionStart, sessionId: sid, source: "codex-desktop"))
        store.recordEvent(event(type: .stop, sessionId: sid, source: "codex"))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.rawSource, "codex-desktop")
        XCTAssertTrue(session?.isCodexDesktop == true)
        XCTAssertEqual(session?.focusAppBundleId, "com.openai.codex")
    }

    /// A machine that has never touched the setting must still expire stale sessions,
    /// otherwise agents that exit without Stop pile up forever.
    func testAutoHideDefaultsOnWhenPreferenceUnset() {
        let key = "auto_hide_inactive_sessions"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
        }

        let store = SessionStore(idleRetentionDuration: 300)
        defer { store.stopTimers() }

        XCTAssertTrue(store.autoHideInactiveSessions)
    }

    func testHeadlessRunningCodexSessionExpiresWithoutStop() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "headless-running-\(UUID().uuidString)"
        var session = AgentSession(
            id: sid,
            projectDir: "/tmp",
            projectName: "test",
            agentSource: .codex,
            status: .active,
            phase: .running,
            eventCount: 3,
            startedAt: Date(timeIntervalSinceNow: -10),
            lastEventAt: Date(timeIntervalSinceNow: -10)
        )
        session.rawSource = "codex-cli"
        store.injectSessionForTesting(session)

        store.expireIdleSessions()

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .ended)
    }

    /// A transcript means the turn is reconcilable against a log, so silence alone
    /// must not retire it. Real Claude Code sessions always carry one.
    func testRunningSessionWithTranscriptDoesNotImplicitlyExpire() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "headless-claude-\(UUID().uuidString)"
        var session = AgentSession(
            id: sid,
            projectDir: "/tmp",
            projectName: "test",
            agentSource: .claudeCode,
            status: .active,
            phase: .running,
            eventCount: 3,
            startedAt: Date(timeIntervalSinceNow: -10),
            lastEventAt: Date(timeIntervalSinceNow: -10)
        )
        session.transcriptPath = "/tmp/session.jsonl"
        store.injectSessionForTesting(session)

        store.expireIdleSessions()

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .active)
    }

    /// No terminal and no transcript → nobody is watching and there is no log to
    /// reconcile against, so a silent running session is retired regardless of which
    /// agent it claims to belong to (some Codex background tasks never emit Stop).
    func testHeadlessRunningSessionExpiresRegardlessOfSource() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "headless-unknown-\(UUID().uuidString)"
        let session = AgentSession(
            id: sid,
            projectDir: "/",
            projectName: "/",
            agentSource: .unknown,
            status: .active,
            phase: .running,
            eventCount: 1,
            startedAt: Date(timeIntervalSinceNow: -10),
            lastEventAt: Date(timeIntervalSinceNow: -10)
        )
        store.injectSessionForTesting(session)

        store.expireIdleSessions()

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .ended)
    }

    func testHeadlessCompactingCodexSessionDoesNotImplicitlyExpire() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "headless-compacting-\(UUID().uuidString)"
        var session = AgentSession(
            id: sid,
            projectDir: "/tmp",
            projectName: "test",
            agentSource: .codex,
            status: .active,
            phase: .compacting,
            eventCount: 3,
            startedAt: Date(timeIntervalSinceNow: -10),
            lastEventAt: Date(timeIntervalSinceNow: -10)
        )
        session.rawSource = "codex-cli"
        store.injectSessionForTesting(session)

        store.expireIdleSessions()

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .active)
    }

    func testHeadlessRunningCodexSessionExpiresFromTimerAndNotifiesObservers() {
        let store = makeStore(idleRetention: 0.05)
        defer { store.stopTimers() }
        let sid = "headless-timer-\(UUID().uuidString)"
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid, source: "codex-cli"))
        let expired = expectation(description: "headless Codex session expired")
        store.onPhasesChanged = {
            if store.sessions.first(where: { $0.id == sid })?.status == .ended {
                expired.fulfill()
            }
        }

        wait(for: [expired], timeout: 1)

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .ended)
    }

    func testRunningSessionWithTerminalDoesNotImplicitlyExpire() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "terminal-running-\(UUID().uuidString)"
        let session = AgentSession(
            id: sid,
            projectDir: "/tmp",
            projectName: "test",
            agentSource: .codex,
            status: .active,
            phase: .running,
            eventCount: 3,
            startedAt: Date(timeIntervalSinceNow: -10),
            lastEventAt: Date(timeIntervalSinceNow: -10),
            terminalPid: 123
        )
        store.injectSessionForTesting(session)

        store.expireIdleSessions()

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .active)
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

    func testIdlePromptTransitionsStoppedSessionToWaitingInput() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-\(UUID().uuidString)"

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(type: .stop, sessionId: sid))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.phase, .idle)

        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .waitingInput)
        XCTAssertNotNil(session?.idleUntil)
    }

    func testUserPromptResumesWaitingInputSession() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-resume-\(UUID().uuidString)"

        store.recordEvent(event(type: .stop, sessionId: sid))
        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .running)
        XCTAssertNil(session?.idleUntil)
    }

    func testWaitingInputSessionExpiresWithIdleRetention() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "waiting-expire-\(UUID().uuidString)"

        store.recordEvent(event(type: .stop, sessionId: sid))
        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))
        store.expireIdleSessions()

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .ended)
    }

    func testLateIdlePromptDoesNotRegressRunningSession() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-late-\(UUID().uuidString)"

        store.recordEvent(event(type: .stop, sessionId: sid))
        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .running)
        XCTAssertNil(session?.idleUntil)
    }

    func testWaitingInputResumeNotifiesPhaseObservers() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-observer-\(UUID().uuidString)"

        store.recordEvent(event(type: .stop, sessionId: sid))
        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))
        var notificationCount = 0
        store.onPhasesChanged = { notificationCount += 1 }

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.phase, .running)
    }

    func testToolActivityClearsWaitingInputDeadline() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-tool-\(UUID().uuidString)"

        store.recordEvent(event(type: .stop, sessionId: sid))
        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))
        XCTAssertNotNil(store.sessions.first(where: { $0.id == sid })?.idleUntil)

        store.recordEvent(event(type: .preToolUse, sessionId: sid))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.phase, .running)
        XCTAssertNil(session?.idleUntil)
    }

    func testIdlePromptDoesNotCreateUnknownSession() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-unknown-\(UUID().uuidString)"

        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))

        XCTAssertNil(store.sessions.first(where: { $0.id == sid }))
    }

    func testIdlePromptDoesNotReactivateEndedSession() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "waiting-ended-\(UUID().uuidString)"

        store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
        store.recordEvent(event(type: .sessionEnd, sessionId: sid))
        store.recordEvent(event(
            type: .notification,
            sessionId: sid,
            notificationType: "idle_prompt"
        ))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.status, .ended)
        XCTAssertEqual(session?.phase, .idle)
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

    func testStartupRestoresCompletedCodexTranscriptToIdleWhenAutoHideIsOff() throws {
        let transcriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("completed-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcriptURL) }
        let terminalRecords = """

        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """
        let terminalData = Data(terminalRecords.utf8)
        let prefixByteCount = 65_537 - terminalData.count
        var transcriptData = Data("你".utf8)
        transcriptData.append(Data(repeating: 0x61, count: prefixByteCount - 3))
        transcriptData.append(terminalData)
        try transcriptData.write(to: transcriptURL, options: .atomic)

        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        store.autoHideInactiveSessions = false
        var session = AgentSession(
            id: "completed-transcript-\(UUID().uuidString)",
            projectDir: "/tmp",
            projectName: "test",
            agentSource: .codex,
            status: .active,
            phase: .running,
            eventCount: 2,
            startedAt: Date(timeIntervalSinceNow: -600),
            lastEventAt: Date(timeIntervalSinceNow: -600),
            activeSubagentCount: 1,
            transcriptPath: transcriptURL.path
        )
        session.rawSource = "codex-desktop"
        store.injectSessionForTesting(session)

        store.runStartupMigration()

        let restored = store.sessions.first(where: { $0.id == session.id })
        XCTAssertEqual(restored?.status, .active)
        XCTAssertEqual(restored?.phase, .idle)
        XCTAssertEqual(restored?.activeSubagentCount, 0)
    }

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
