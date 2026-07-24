import XCTest
@testable import PeachyPet

final class SessionSwitcherTitleTests: XCTestCase {
    func testProjectAndTitleUseMiddleDot() {
        let result = formatSessionSwitcherProjectLabel(
            project: "namiwork-core",
            title: "解决 release 分支冲突"
        )
        XCTAssertEqual(result, "namiwork-core · 解决 release 分支冲突")
    }

    func testProjectOnlyOmitsMiddleDot() {
        let result = formatSessionSwitcherProjectLabel(
            project: "namiwork-core",
            title: nil
        )
        XCTAssertEqual(result, "namiwork-core")
    }

    func testEmptyTitleOmitsMiddleDot() {
        let result = formatSessionSwitcherProjectLabel(
            project: "namiwork-core",
            title: ""
        )
        XCTAssertEqual(result, "namiwork-core")
    }
}
