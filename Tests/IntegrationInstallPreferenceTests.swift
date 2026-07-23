import XCTest
@testable import PeachyPet

final class IntegrationInstallPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "IntegrationInstallPreferenceTests")!
        defaults.removePersistentDomain(forName: "IntegrationInstallPreferenceTests")
    }

    func testIntegrationDefaultsToEnabled() {
        XCTAssertTrue(PeachyEventBus.isInstallEnabled(for: .claudeCode, defaults: defaults))
        XCTAssertTrue(PeachyEventBus.isInstallEnabled(for: .codex, defaults: defaults))
    }

    func testStoredDisabledPreferencePreventsInstall() {
        PeachyEventBus.setInstallEnabled(false, for: .claudeCode, defaults: defaults)
        PeachyEventBus.setInstallEnabled(false, for: .codex, defaults: defaults)

        XCTAssertFalse(PeachyEventBus.isInstallEnabled(for: .claudeCode, defaults: defaults))
        XCTAssertFalse(PeachyEventBus.isInstallEnabled(for: .codex, defaults: defaults))
    }
}
