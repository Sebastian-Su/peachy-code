import XCTest
@testable import PeachyPet

final class LanguageManagerTests: XCTestCase {
    override func setUp() {
        // Locate the resource bundle produced by the PeachyPet executable target.
        // In SPM the bundle lives next to the test binary as PeachyPet_PeachyPet.bundle.
        let testBinDir = (Bundle(for: LanguageManagerTests.self).bundlePath as NSString).deletingLastPathComponent
        let bundlePath = (testBinDir as NSString).appendingPathComponent("PeachyPet_PeachyPet.bundle")
        if let resourceBundle = Bundle(path: bundlePath) {
            LanguageManager.shared.setSourceBundle(resourceBundle)
        }
        LanguageManager.shared.setLanguage(.en)
    }

    override func tearDown() {
        LanguageManager.shared.setLanguage(.en)
    }

    func testEnglishFallback() {
        LanguageManager.shared.setLanguage(.en)
        XCTAssertEqual(t("settings.title"), "Settings")
    }

    func testChineseTranslation() {
        LanguageManager.shared.setLanguage(.zh)
        XCTAssertEqual(t("settings.title"), "设置")
    }

    func testUnknownKeyReturnsSelf() {
        LanguageManager.shared.setLanguage(.en)
        XCTAssertEqual(t("nonexistent.key"), "nonexistent.key")
    }

    func testLanguagePersistence() {
        LanguageManager.shared.setLanguage(.zh)
        let stored = UserDefaults.standard.string(forKey: "appLanguage")
        XCTAssertEqual(stored, "zh")
    }
}
