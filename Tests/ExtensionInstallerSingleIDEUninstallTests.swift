import XCTest
@testable import PeachyPet

final class ExtensionInstallerSingleIDEUninstallTests: XCTestCase {
    func testUninstallUnknownIDEThrowsNoIDEFound() {
        XCTAssertThrowsError(try ExtensionInstaller.uninstall(command: "not-a-supported-ide")) { error in
            XCTAssertEqual(
                (error as? ExtensionInstaller.ExtensionError)?.errorDescription,
                ExtensionInstaller.ExtensionError.noIDEFound.errorDescription
            )
        }
    }
}
