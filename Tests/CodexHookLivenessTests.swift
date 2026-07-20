import XCTest
@testable import PeachyPet

@MainActor
final class CodexHookLivenessTests: XCTestCase {
    func testMarkAndQuery() {
        let liveness = CodexHookLiveness()
        XCTAssertFalse(liveness.isLive(sessionId: "s1"))
        liveness.markLive(sessionId: "s1")
        XCTAssertTrue(liveness.isLive(sessionId: "s1"))
    }

    func testNilSessionIsNeverLive() {
        let liveness = CodexHookLiveness()
        liveness.markLive(sessionId: "s1")
        XCTAssertFalse(liveness.isLive(sessionId: nil))
    }

    func testClearRemovesLiveness() {
        let liveness = CodexHookLiveness()
        liveness.markLive(sessionId: "s1")
        liveness.clear(sessionId: "s1")
        XCTAssertFalse(liveness.isLive(sessionId: "s1"))
    }
}
