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
}
