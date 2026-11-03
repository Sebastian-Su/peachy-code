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

/// Permission cards: allow (white label on accent) and deny (half-strength
/// text on the card) must stay readable and distinct in every skin.
final class PermissionCardSkinTests: XCTestCase {
    func testAllowAndDenyStayReadableInEverySkin() {
        for skin in Skin.builtIn {
            XCTAssertGreaterThanOrEqual(Skin.contrastRatio("#ffffff", skin.accent), 3.0, "\(skin.id) allow")
            let deny = Skin.blend(skin.text, alpha: 0.5, over: skin.surface)
            XCTAssertGreaterThanOrEqual(Skin.contrastRatio(deny, skin.surface), 3.0, "\(skin.id) deny")
            XCTAssertGreaterThanOrEqual(Skin.contrastRatio(skin.accent, skin.surface), 2.5, "\(skin.id) allow vs card")
        }
    }

    func testBlendMixesChannels() {
        XCTAssertEqual(Skin.blend("#000000", alpha: 0.5, over: "#ffffff"), "#808080")
    }
}

final class CustomSkinTests: XCTestCase {
    private let samples = ["#ffffff", "#000000", "#ffff00", "#00ff00", "#0000ff", "#ff00ff", "#7f7f7f", "#f95d02", "#d4a843"]

    func testDerivedSkinKeepsBodyTextReadableForAnyAccent() {
        for accent in samples {
            let skin = Skin.custom(accent: accent)
            for text in [skin.text, skin.textMuted] {
                for surface in [skin.background, skin.surface, skin.sidebar] {
                    XCTAssertGreaterThanOrEqual(Skin.contrastRatio(text, surface), 4.5, "\(accent): \(text) on \(surface)")
                }
            }
            XCTAssertGreaterThanOrEqual(Skin.contrastRatio("#ffffff", skin.accent), 3.0, "\(accent) allow label")
            XCTAssertGreaterThanOrEqual(Skin.contrastRatio(skin.accentText, skin.background), 4.5, "\(accent) accent text")
        }
    }

    func testCustomSelectionPersistsWithItsAccent() {
        let suite = "CustomSkinTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        SkinStore(defaults: defaults).selectCustom(accent: "#2f8a78")
        let reloaded = SkinStore(defaults: defaults).current
        XCTAssertEqual(reloaded.id, "custom")
        XCTAssertEqual(reloaded, Skin.custom(accent: "#2f8a78"))
    }

    func testCustomWithUnreadableAccentFallsBackToDefault() {
        XCTAssertEqual(Skin.resolve(storedValue: "custom", customAccent: nil).id, "cream")
        XCTAssertEqual(Skin.resolve(storedValue: "custom", customAccent: "zzz").id, "cream")
    }
}
