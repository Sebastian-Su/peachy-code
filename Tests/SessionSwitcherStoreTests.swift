import XCTest
@testable import PeachyPet

@MainActor
final class SessionSwitcherStoreTests: XCTestCase {
    private func session(id: String, subagents: Int, date: Date) -> AgentSession {
        AgentSession(
            id: id,
            projectDir: "/tmp/\(id)",
            projectName: id,
            agentSource: .claudeCode,
            status: .active,
            phase: .running,
            eventCount: 1,
            startedAt: date,
            lastEventAt: date,
            activeSubagentCount: subagents
        )
    }

    func testRefreshUpdatesSubagentCountAndPreservesSelection() {
        let store = SessionSwitcherStore()
        let now = Date()
        store.open(sessions: [
            session(id: "A", subagents: 0, date: now),
            session(id: "B", subagents: 0, date: now.addingTimeInterval(-1)),
        ])
        store.selectIndex(1)

        store.refresh(sessions: [
            session(id: "A", subagents: 3, date: now),
            session(id: "B", subagents: 2, date: now.addingTimeInterval(1)),
        ])

        XCTAssertEqual(store.sessions.map(\.id), ["B", "A"])
        XCTAssertEqual(store.selectedSession?.id, "B")
        XCTAssertEqual(store.selectedSession?.activeSubagentCount, 2)
        XCTAssertEqual(store.sessions.first(where: { $0.id == "A" })?.activeSubagentCount, 3)
        store.close()
    }

    func testCommandHoldPausesAutoDismiss() {
        let store = SessionSwitcherStore(autoDismissInterval: 0.05)
        let dismissed = expectation(description: "switcher stays open while Command is held")
        dismissed.isInverted = true
        store.onAutoDismiss = { dismissed.fulfill() }

        store.open(sessions: [session(id: "A", subagents: 0, date: Date())])
        store.setAutoDismissPaused(true)

        wait(for: [dismissed], timeout: 0.1)
        XCTAssertTrue(store.isActive)
        store.close()
        XCTAssertFalse(store.isAutoDismissPaused)
    }

    func testCommandReleaseRestartsFullAutoDismissInterval() {
        let store = SessionSwitcherStore(autoDismissInterval: 0.4)
        let now = Date()
        store.open(sessions: [session(id: "A", subagents: 0, date: now)])
        RunLoop.main.run(until: now.addingTimeInterval(0.3))
        store.setAutoDismissPaused(true)

        let dismissedWhilePaused = expectation(description: "Command hold pauses past the original deadline")
        dismissedWhilePaused.isInverted = true
        store.onAutoDismiss = { dismissedWhilePaused.fulfill() }
        wait(for: [dismissedWhilePaused], timeout: 0.2)

        store.setAutoDismissPaused(false)
        let dismissedTooEarly = expectation(description: "release restarts the full interval")
        dismissedTooEarly.isInverted = true
        store.onAutoDismiss = { dismissedTooEarly.fulfill() }
        wait(for: [dismissedTooEarly], timeout: 0.25)
        XCTAssertTrue(store.isActive)

        let dismissed = expectation(description: "switcher dismisses after the restarted interval")
        store.onAutoDismiss = { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 0.3)
        XCTAssertFalse(store.isActive)
    }

    func testArrowSelectionRestartsFullAutoDismissInterval() {
        let store = SessionSwitcherStore(autoDismissInterval: 0.4)
        let dismissedTooEarly = expectation(description: "arrow selection restarts the full interval")
        dismissedTooEarly.isInverted = true
        store.onAutoDismiss = { dismissedTooEarly.fulfill() }
        let now = Date()

        store.open(sessions: [
            session(id: "A", subagents: 0, date: now),
            session(id: "B", subagents: 0, date: now.addingTimeInterval(-1)),
        ])
        RunLoop.main.run(until: now.addingTimeInterval(0.3))
        store.selectNext()

        wait(for: [dismissedTooEarly], timeout: 0.25)
        XCTAssertTrue(store.isActive)

        let dismissed = expectation(description: "switcher dismisses after the restarted interval")
        store.onAutoDismiss = { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 0.3)
        XCTAssertFalse(store.isActive)
    }

    func testArrowSelectionDoesNotRestartTimerWhilePaused() {
        let store = SessionSwitcherStore(autoDismissInterval: 0.05)
        let dismissed = expectation(description: "paused switcher stays open after arrow selection")
        dismissed.isInverted = true
        store.onAutoDismiss = { dismissed.fulfill() }
        let now = Date()

        store.open(sessions: [
            session(id: "A", subagents: 0, date: now),
            session(id: "B", subagents: 0, date: now.addingTimeInterval(-1)),
        ])
        store.setAutoDismissPaused(true)
        store.selectPrevious()

        wait(for: [dismissed], timeout: 0.1)
        XCTAssertTrue(store.isActive)
        store.close()
    }

    func testCommandStateChangesDoNotStartTimerWhileClosed() {
        let store = SessionSwitcherStore(autoDismissInterval: 0.01)
        let dismissed = expectation(description: "closed switcher never auto-dismisses")
        dismissed.isInverted = true
        store.onAutoDismiss = { dismissed.fulfill() }

        store.setAutoDismissPaused(true)
        store.setAutoDismissPaused(false)

        wait(for: [dismissed], timeout: 0.03)
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.isAutoDismissPaused)
    }
}
