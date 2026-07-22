import XCTest
@testable import PeachyPet

final class HookInstallerEventsTests: XCTestCase {
    func testSubagentLifecycleHooksAreRegisteredAsPair() {
        XCTAssertTrue(HookInstaller.hookEvents.contains("SubagentStart"))
        XCTAssertTrue(HookInstaller.hookEvents.contains("SubagentStop"))
    }
}
