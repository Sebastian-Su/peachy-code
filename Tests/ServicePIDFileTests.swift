import XCTest
@testable import PeachyPet

final class ServicePIDFileTests: XCTestCase {
    private func entry(_ command: String, cwd: String? = "/Users/u/finance") -> ServiceEntry {
        ServiceEntry(id: "x", name: "X", kind: .service, command: command, cwd: cwd, url: nil, port: nil, env: [:], note: nil,
                     fileURL: URL(fileURLWithPath: "/tmp/x.json"), modifiedAt: nil, pidFile: "/tmp/x.pid")
    }

    func testCommandSubstitutionIsAScriptNotAProgram() {
        XCTAssertNil(ServiceValidity.firstExecutable(#"pid=$(/usr/bin/plutil -extract pid raw -o - /tmp/p.json); exec python launch.py"#))
        XCTAssertNil(ServiceValidity.firstExecutable("-extract pid"))
        XCTAssertEqual(ServiceValidity.firstExecutable("PORT=8188 exec python main.py"), "python")
        XCTAssertEqual(ServiceValidity.check(entry(#"pid=$(/usr/bin/plutil -extract pid raw -o - /tmp/p.json)"#, cwd: nil),
                                             resolves: { _ in false }), .ok)
    }

    func testReadsPlainOrJSONPIDFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appendingPathComponent("a.pid")
        try "27175\n".write(to: plain, atomically: true, encoding: .utf8)
        let json = directory.appendingPathComponent("b.json")
        try #"{"pid": 27175, "mode": "read_only_reports"}"#.write(to: json, atomically: true, encoding: .utf8)
        let bad = directory.appendingPathComponent("c.json")
        try #"{"pid": "soon"}"#.write(to: bad, atomically: true, encoding: .utf8)

        XCTAssertEqual(ServicePIDFile.read(plain.path), 27175)
        XCTAssertEqual(ServicePIDFile.read(json.path), 27175)
        XCTAssertNil(ServicePIDFile.read(bad.path))
        XCTAssertNil(ServicePIDFile.read(directory.appendingPathComponent("missing").path))
    }

    func testRegistryReadsPIDFileWithTilde() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try #"{"schema":1,"name":"Reports","kind":"service","command":"python launch.py","pidFile":"~/run/reports.json"}"#
            .write(to: directory.appendingPathComponent("reports.json"), atomically: true, encoding: .utf8)
        guard case .valid(let entry) = ServiceRegistry.load(from: directory).first?.state else { return XCTFail("invalid") }
        XCTAssertEqual(entry.pidFile, NSHomeDirectory() + "/run/reports.json")
    }

    func testLivePIDFileProcessIsExternalOnlyWhenItMatches() {
        let e = entry("exec python launch-reports.py")
        let ours = PortListener(pid: 27175, command: "node --import tsx src/main.ts", cwd: "/Users/u/finance")
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: nil, listener: nil, pidFileProcess: ours),
                       .external(pid: 27175, command: "node --import tsx src/main.ts"))
        // A reused PID now belongs to something else: the service is not running.
        let reused = PortListener(pid: 27175, command: "/usr/libexec/trustd", cwd: "/")
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: nil, listener: nil, pidFileProcess: reused), .stopped)
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: 12, listener: nil, pidFileProcess: ours), .running(pid: 12))
    }
}
