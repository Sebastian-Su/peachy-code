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

final class BuiltInSkinTests: XCTestCase {
    func testBuiltInSkinsInOrder() {
        XCTAssertEqual(Skin.builtIn.map(\.id), ["cream", "peach", "dusk", "night"])
    }

    func testEveryBuiltInSkinMeetsBodyContrast() {
        for skin in Skin.builtIn {
            for text in [skin.text, skin.textMuted] {
                for surface in [skin.background, skin.surface, skin.sidebar] {
                    XCTAssertGreaterThanOrEqual(
                        Skin.contrastRatio(text, surface), 4.5,
                        "\(skin.id): \(text) on \(surface)"
                    )
                }
            }
        }
    }

    func testPeachKeepsThePreviousBrandColors() {
        let peach = Skin.resolve(storedValue: "peach")
        XCTAssertEqual(peach.accent, "#f95d02")
        XCTAssertEqual(peach.text, "#23113c")
        XCTAssertEqual(peach.background, "#faf9f7")
        XCTAssertEqual(peach.surface, "#ffffff")
    }

    func testOnlyNightIsDark() {
        XCTAssertEqual(Skin.builtIn.filter(\.isDark).map(\.id), ["night"])
    }

    func testSelectionPersistsAcrossStores() {
        let suite = "SkinTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        SkinStore(defaults: defaults).select(Skin.resolve(storedValue: "dusk"))
        XCTAssertEqual(SkinStore(defaults: defaults).current.id, "dusk")
    }
}
