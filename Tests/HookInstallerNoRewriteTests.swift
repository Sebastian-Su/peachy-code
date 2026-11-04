import XCTest
@testable import PeachyPet

/// Launching re-registers hooks for enabled integrations; when nothing changed
/// the user's config file must not be rewritten.
final class HookInstallerNoRewriteTests: XCTestCase {
    private var dir: URL!
    private let old = Date(timeIntervalSince1970: 1_000_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("no-rewrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func mtime(_ path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private func age(_ path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
    }

    func testClaudeReinstallLeavesUnchangedSettingsAlone() throws {
        let path = dir.appendingPathComponent("settings.json").path
        try HookInstaller.install(settingsPath: path, ensureScript: false)
        try age(path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        try HookInstaller.install(settingsPath: path, ensureScript: false)

        XCTAssertEqual(try mtime(path), old)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    /// The user's own formatting (key order, indentation) does not count as a change.
    func testClaudeReinstallIgnoresFormattingDifferences() throws {
        let path = dir.appendingPathComponent("settings.json").path
        try HookInstaller.install(settingsPath: path, ensureScript: false)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))  // compact, unsorted
        try age(path)

        try HookInstaller.install(settingsPath: path, ensureScript: false)

        XCTAssertEqual(try mtime(path), old)
    }

    func testCodexReinstallLeavesUnchangedHooksAlone() throws {
        let path = dir.appendingPathComponent("hooks.json").path
        try CodexHookInstaller.install(hooksJSONPath: path, ensureScript: false)
        try age(path)

        try CodexHookInstaller.install(hooksJSONPath: path, ensureScript: false)

        XCTAssertEqual(try mtime(path), old)
    }

    func testRealChangeIsStillWritten() throws {
        let path = dir.appendingPathComponent("hooks.json").path
        try Data(#"{"hooks":{}}"#.utf8).write(to: URL(fileURLWithPath: path))
        try age(path)

        try CodexHookInstaller.install(hooksJSONPath: path, ensureScript: false)

        XCTAssertNotEqual(try mtime(path), old)
        XCTAssertTrue(CodexHookInstaller.isRegistered(hooksJSONPath: path))
    }
}
