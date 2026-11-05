import XCTest
@testable import PeachyPet

final class ServiceValidityTests: XCTestCase {
    private func entry(_ command: String, cwd: String? = nil) -> ServiceEntry {
        ServiceEntry(id: "v", name: "V", kind: .service, command: command, cwd: cwd, url: nil, port: nil, env: [:], note: nil,
                     fileURL: URL(fileURLWithPath: "/tmp/v.json"), modifiedAt: nil)
    }
    private let resolves: (String) -> Bool = { ["ollama", "python3", "conda"].contains($0) }

    /// S21: only three checks — cwd exists, first executable resolves, file parses (parse is P1).
    func testMissingWorkingDirectory() {
        XCTAssertEqual(ServiceValidity.check(entry("ollama serve", cwd: "/nonexistent/dir"), resolves: resolves),
                       .missingDirectory("/nonexistent/dir"))
    }

    func testCommandNotFound() {
        XCTAssertEqual(ServiceValidity.check(entry("comfyui-start --port 1"), resolves: resolves), .commandNotFound("comfyui-start"))
    }

    func testScriptPathMustExist() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString).sh")
        XCTAssertEqual(ServiceValidity.check(entry("\(script.path) --x"), resolves: resolves), .commandNotFound(script.path))
        try Data("#!/bin/sh\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        XCTAssertEqual(ServiceValidity.check(entry("\(script.path) --x"), resolves: resolves), .ok)
    }

    /// Relative scripts resolve against cwd; env assignments and `exec` are skipped.
    func testFirstExecutableSkipsEnvAndExec() {
        XCTAssertEqual(ServiceValidity.check(entry("FOO=1 exec ollama serve"), resolves: resolves), .ok)
        XCTAssertEqual(ServiceValidity.check(entry("./start.sh", cwd: "/tmp"), resolves: resolves), .commandNotFound("/tmp/start.sh"))
        let name = "missing-\(UUID().uuidString).sh"
        XCTAssertEqual(ServiceValidity.check(entry("~/\(name)"), resolves: resolves),
                       .commandNotFound(NSHomeDirectory() + "/" + name))
    }

    /// S22: delete moves the file to the Trash, not a permanent delete.
    func testDeleteMovesToTrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("del-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("gone.json")
        try Data("{}".utf8).write(to: file)
        let trashed = try XCTUnwrap(ServiceRegistry.moveToTrash(file))
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertTrue(trashed.path.contains("/.Trash/"))
    }
}
