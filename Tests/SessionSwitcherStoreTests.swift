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

    func testDefaultSystemTimerDismissesOpenSwitcher() async {
        let store = SessionSwitcherStore(autoDismissInterval: 0.01)
        let dismissed = expectation(description: "system timer dismisses the switcher")
        store.onAutoDismiss = { dismissed.fulfill() }
        store.open(sessions: [session(id: "A", subagents: 0, date: Date())])

        await fulfillment(of: [dismissed], timeout: 3)

        XCTAssertFalse(store.isActive)
    }

    // Real run-loop deadlines depend on CI load and pending SwiftUI work.
    // Advance the same Timer callbacks explicitly instead of sleeping between assertions.
    private final class TestClock {
        private var time: TimeInterval = 0
        private var timers: [(deadline: TimeInterval, timer: Timer)] = []

        func schedule(interval: TimeInterval, action: @escaping (Timer) -> Void) -> Timer {
            let timer = Timer(timeInterval: interval, repeats: false, block: action)
            timers.append((time + interval, timer))
            return timer
        }

        func advance(by interval: TimeInterval) async {
            time += interval
            for entry in timers where entry.deadline <= time && entry.timer.isValid {
                entry.timer.fire()
                entry.timer.invalidate()
            }
            timers.removeAll { !$0.timer.isValid }
            // The store delivers timer actions on the main queue. Drain them before asserting.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testCommandHoldPausesAutoDismiss() async {
        let clock = TestClock()
        let store = SessionSwitcherStore(autoDismissInterval: 0.05, scheduleTimer: clock.schedule)
        var dismissals = 0
        store.onAutoDismiss = { dismissals += 1 }

        store.open(sessions: [session(id: "A", subagents: 0, date: Date())])
        store.setAutoDismissPaused(true)

        await clock.advance(by: 0.1)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(store.isActive)
        store.close()
        XCTAssertFalse(store.isAutoDismissPaused)
    }

    func testCommandReleaseRestartsFullAutoDismissInterval() async {
        let clock = TestClock()
        let store = SessionSwitcherStore(autoDismissInterval: 0.4, scheduleTimer: clock.schedule)
        var dismissals = 0
        store.onAutoDismiss = { dismissals += 1 }
        store.open(sessions: [session(id: "A", subagents: 0, date: Date())])
        await clock.advance(by: 0.3)
        store.setAutoDismissPaused(true)

        await clock.advance(by: 0.2)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(store.isActive)

        store.setAutoDismissPaused(false)
        await clock.advance(by: 0.25)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(store.isActive)

        await clock.advance(by: 0.16)
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(store.isActive)
    }

    func testArrowSelectionRestartsFullAutoDismissInterval() async {
        let clock = TestClock()
        let store = SessionSwitcherStore(autoDismissInterval: 0.4, scheduleTimer: clock.schedule)
        var dismissals = 0
        store.onAutoDismiss = { dismissals += 1 }
        let now = Date()
        store.open(sessions: [
            session(id: "A", subagents: 0, date: now),
            session(id: "B", subagents: 0, date: now.addingTimeInterval(-1)),
        ])
        await clock.advance(by: 0.3)
        store.selectNext()

        await clock.advance(by: 0.25)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(store.isActive)

        await clock.advance(by: 0.16)
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(store.isActive)
    }

    func testArrowSelectionDoesNotRestartTimerWhilePaused() async {
        let clock = TestClock()
        let store = SessionSwitcherStore(autoDismissInterval: 0.05, scheduleTimer: clock.schedule)
        var dismissals = 0
        store.onAutoDismiss = { dismissals += 1 }
        let now = Date()
        store.open(sessions: [
            session(id: "A", subagents: 0, date: now),
            session(id: "B", subagents: 0, date: now.addingTimeInterval(-1)),
        ])
        store.setAutoDismissPaused(true)
        store.selectPrevious()

        await clock.advance(by: 0.1)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(store.isActive)
        store.close()
    }

    func testCommandStateChangesDoNotStartTimerWhileClosed() async {
        let clock = TestClock()
        let store = SessionSwitcherStore(autoDismissInterval: 0.01, scheduleTimer: clock.schedule)
        var dismissals = 0
        store.onAutoDismiss = { dismissals += 1 }

        store.setAutoDismissPaused(true)
        store.setAutoDismissPaused(false)

        await clock.advance(by: 0.03)
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(store.isActive)
        XCTAssertFalse(store.isAutoDismissPaused)
    }
}
