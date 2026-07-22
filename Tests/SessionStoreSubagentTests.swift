import XCTest
@testable import PeachyPet

@MainActor
final class SessionStoreSubagentTests: XCTestCase {
    private func makeStore(idleRetention: TimeInterval = 300) -> SessionStore {
        SessionStore(idleRetentionDuration: idleRetention)
    }

    private func event(
        _ type: HookEventType,
        sessionId: String,
        agentId: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: type.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/subagent-test",
            source: "claude-code",
            agentId: agentId
        )
    }

    func testDistinctStartsCountAndDuplicateStartIsIdempotent() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "subagents-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "B"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.activeSubagentCount, 2)
        XCTAssertEqual(session?.phase, .running)
    }

    func testStopRemovesExactAgentAndUnknownStopDoesNotChangeCount() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "subagent-stop-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "B"))
        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "unknown"))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 2)

        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 1)
    }

    func testAnonymousAndIdentifiedSubagentsAreCountedTogether() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "mixed-subagents-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 2)

        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 1)

        store.recordEvent(event(.subagentStop, sessionId: sid))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 0)
    }

    func testSubagentStartCreatesRunningSessionWhenSessionStartWasMissed() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "subagent-first-\(UUID().uuidString)"

        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.status, .active)
        XCTAssertEqual(session?.phase, .running)
        XCTAssertEqual(session?.activeSubagentCount, 1)
    }

    func testStopStopFailureAndSessionEndClearSubagents() {
        for terminalEvent in [HookEventType.stop, .stopFailure, .sessionEnd] {
            let store = makeStore()
            let sid = "clear-\(terminalEvent.rawValue)-\(UUID().uuidString)"
            store.recordEvent(event(.sessionStart, sessionId: sid))
            store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
            store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "B"))

            store.recordEvent(event(terminalEvent, sessionId: sid))

            XCTAssertEqual(
                store.sessions.first(where: { $0.id == sid })?.activeSubagentCount,
                0,
                "\(terminalEvent.rawValue) must clear subagents"
            )
            store.stopTimers()
        }
    }

    func testIdleExpiryClearsSubagents() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "expire-subagents-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.stop, sessionId: sid))
        store.expireIdleSessions()

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.status, .ended)
        XCTAssertEqual(session?.activeSubagentCount, 0)
    }

    func testStartupMigrationClearsSubagentsFromExpiredSession() {
        let store = makeStore(idleRetention: 0)
        defer { store.stopTimers() }
        let sid = "migrate-subagents-\(UUID().uuidString)"
        var session = AgentSession(
            id: sid,
            projectDir: "/tmp/subagent-test",
            projectName: "subagent-test",
            agentSource: .claudeCode,
            status: .active,
            phase: .idle,
            eventCount: 1,
            startedAt: Date(timeIntervalSinceNow: -10),
            lastEventAt: Date(timeIntervalSinceNow: -10),
            activeSubagentCount: 3
        )
        session.idleUntil = Date(timeIntervalSinceNow: -1)
        store.injectSessionForTesting(session)

        store.runStartupMigration()

        let migrated = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(migrated?.status, .ended)
        XCTAssertEqual(migrated?.activeSubagentCount, 0)
    }

    func testStartupMigrationClearsPersistedCountWithoutAgentIds() {
        let store = makeStore(idleRetention: 300)
        defer { store.stopTimers() }
        let sid = "restart-subagents-\(UUID().uuidString)"
        let session = AgentSession(
            id: sid,
            projectDir: "/tmp/subagent-test",
            projectName: "subagent-test",
            agentSource: .claudeCode,
            status: .active,
            phase: .running,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date(),
            activeSubagentCount: 3,
            terminalPid: Int(ProcessInfo.processInfo.processIdentifier)
        )
        store.injectSessionForTesting(session)

        store.runStartupMigration()

        let migrated = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(migrated?.status, .active)
        XCTAssertEqual(migrated?.activeSubagentCount, 0)
    }

    func testSubagentCountChangeNotifiesObservers() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "notify-subagents-\(UUID().uuidString)"
        var notifications = 0
        store.onPhasesChanged = { notifications += 1 }

        store.recordEvent(event(.sessionStart, sessionId: sid))
        notifications = 0
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))

        XCTAssertEqual(notifications, 2)
    }
}
