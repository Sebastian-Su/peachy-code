import XCTest
@testable import PeachyPet

final class InboxPendingTests: XCTestCase {
    func testEachRequestAndWaitingSessionAppearsOnceNewestFirst() {
        let p1 = UUID(), p2 = UUID()
        let items = InboxPending.build(
            permissions: [(p1, Date(timeIntervalSince1970: 10)), (p2, Date(timeIntervalSince1970: 30)), (p1, Date(timeIntervalSince1970: 10))],
            waitingSessions: [("s1", Date(timeIntervalSince1970: 20))]
        )
        XCTAssertEqual(items, [.permission(p2), .waitingInput("s1"), .permission(p1)])
    }

    func testEmptyWhenNothingIsWaiting() {
        XCTAssertTrue(InboxPending.build(permissions: [], waitingSessions: []).isEmpty)
    }
}
