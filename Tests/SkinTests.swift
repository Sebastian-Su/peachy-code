import XCTest
@testable import PeachyPet

final class SkinTests: XCTestCase {
    func testDefaultsToCreamWhenNothingStored() {
        XCTAssertEqual(Skin.resolve(storedValue: nil).id, "cream")
    }

    func testUnreadableStoredValueFallsBackToCream() {
        XCTAssertEqual(Skin.resolve(storedValue: "no-such-skin").id, "cream")
        XCTAssertEqual(Skin.resolve(storedValue: 42).id, "cream")
        XCTAssertEqual(Skin.resolve(storedValue: Data([0xff, 0x00])).id, "cream")
    }

    func testCreamBodyTextMeetsContrastMinimum() {
        let cream = Skin.cream
        for text in [cream.text, cream.textMuted] {
            for surface in [cream.background, cream.surface] {
                XCTAssertGreaterThanOrEqual(
                    Skin.contrastRatio(text, surface), 4.5,
                    "\(text) on \(surface)"
                )
            }
        }
    }
}
