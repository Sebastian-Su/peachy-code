import XCTest
@testable import PeachyPet

final class LanguageManagerTests: XCTestCase {
    override func setUp() {
        // The PeachyPet_PeachyPet.bundle lives next to PeachyPetPackageTests.xctest
        // in the same debug directory. Point LanguageManager at that directory.
        let xctest = Bundle(for: LanguageManagerTests.self).bundlePath
        let debugDir = (xctest as NSString).deletingLastPathComponent
        LanguageManager.shared.setResourceRootPath(debugDir)
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
