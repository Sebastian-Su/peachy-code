import XCTest
@testable import PeachyPet

final class SessionSwitcherIndicatorTests: XCTestCase {
    func testIndicatorCapacityFillsAvailableWidthWithRightInset() {
        XCTAssertEqual(subagentIndicatorCapacity(availableWidth: 400), 28)
        XCTAssertEqual(subagentIndicatorCapacity(availableWidth: 0), 0)
    }

    func testIndicatorIsPlacedBelowTextContainer() {
        XCTAssertEqual(
            subagentIndicatorTopOffset(containerHeight: 24),
            26
        )
    }
}
