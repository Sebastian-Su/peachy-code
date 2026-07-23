import XCTest
@testable import PeachyPet

final class LocalStorageIsolationTests: XCTestCase {
    func testAppSupportDirIsIsolatedUnderTests() {
        let realUserDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PeachyPet", isDirectory: true)

        XCTAssertNotEqual(
            LocalStorage.appSupportDir.standardizedFileURL,
            realUserDir.standardizedFileURL,
            "Tests must not read or write the real PeachyPet Application Support directory"
        )
    }
}
