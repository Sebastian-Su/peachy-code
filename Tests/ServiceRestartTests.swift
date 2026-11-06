import XCTest
@testable import PeachyPet

final class ServiceRestartTests: XCTestCase {
    private func entry(_ id: String = "restart-\(UUID().uuidString.prefix(8).lowercased())") -> ServiceEntry {
        ServiceEntry(id: id, name: "R", kind: .service, command: "new-server --port 1", cwd: nil, url: nil, port: 1, env: [:], note: nil,
                     fileURL: URL(fileURLWithPath: "/tmp/r.json"), modifiedAt: nil)
    }

    /// An unapproved restart of an external service must name the old process in the same dialog.
    func testRestartChoosesTheRightDialog() {
        let external = ServiceStatus.external(pid: 9, command: "old")
        XCTAssertEqual(ServiceRestartFlow.next(status: external, approval: .neverApproved),
                       .confirmCommandAndReplace(pid: 9, command: "old"))
        XCTAssertEqual(ServiceRestartFlow.next(status: external, approval: .changed([.command])),
                       .confirmCommandAndReplace(pid: 9, command: "old"))
        XCTAssertEqual(ServiceRestartFlow.next(status: external, approval: .approved),
                       .confirmStopThenStart(pid: 9, command: "old"))
        XCTAssertEqual(ServiceRestartFlow.next(status: .running(pid: 3), approval: .approved), .restartManaged)
        XCTAssertEqual(ServiceRestartFlow.next(status: .running(pid: 3), approval: .neverApproved), .confirmCommand)
        XCTAssertEqual(ServiceRestartFlow.next(status: .stopped, approval: .neverApproved), .confirmCommand)
        XCTAssertEqual(ServiceRestartFlow.next(status: .portBusy(pid: 9, command: "x"), approval: .approved), .none)
    }

    /// The bug: confirming started the new job while the old process still held the port.
    func testConfirmedReplaceEndsOldProcessBeforeStartingNew() throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["60"]
        try old.run()
        defer { if old.isRunning { old.terminate() } }
        let command = PortListener.describe(pid: old.processIdentifier).command
        XCTAssertFalse(command.isEmpty)

        let bootstrapped = expectation(description: "bootstrap")
        var oldAliveAtBootstrap: Bool?
        let suite = "restart-\(UUID().uuidString)"
        let approvals = ServiceApproval(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let launcher = ServiceLauncher(approvals: approvals, runLaunchctl: { args in
            if args.first == "bootstrap" {
                oldAliveAtBootstrap = kill(old.processIdentifier, 0) == 0
                bootstrapped.fulfill()
                return (0, "")
            }
            return (113, "")
        })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("restart-\(UUID().uuidString)")
        let store = ServiceStore(directory: dir, launcher: launcher, approvals: approvals)
        let e = entry()
        store.approveAndReplace(e, pid: old.processIdentifier, command: command)
        wait(for: [bootstrapped], timeout: 12)
        XCTAssertEqual(oldAliveAtBootstrap, false, "old process must be gone before the new job starts")
        XCTAssertEqual(approvals.status(of: e), .approved)
        launcher.stop(id: e.id)
    }

    /// X2: if the pid now runs something else, nothing is signalled and nothing starts.
    func testReplaceAbortsWhenPidNoLongerMatches() throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["60"]
        try other.run()
        defer { if other.isRunning { other.terminate() } }

        var started = false
        let suite = "restart-\(UUID().uuidString)"
        let approvals = ServiceApproval(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let launcher = ServiceLauncher(approvals: approvals, runLaunchctl: { args in
            if args.first == "bootstrap" { started = true }
            return (113, "")
        })
        let store = ServiceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString)"),
                                 launcher: launcher, approvals: approvals)
        store.approveAndReplace(entry(), pid: other.processIdentifier, command: "some other command")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(other.isRunning)
        XCTAssertFalse(started)
    }

    /// Same race for our own job: confirming a changed command while it runs must
    /// remove the old job and wait for its process before bootstrapping.
    func testApprovingChangedCommandWhileManagedRunningWaitsForOldProcess() throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["60"]
        try old.run()
        defer { if old.isRunning { old.terminate() } }
        let pid = old.processIdentifier

        let bootstrapped = expectation(description: "bootstrap")
        var aliveAtBootstrap: Bool?
        let suite = "restart-\(UUID().uuidString)"
        let approvals = ServiceApproval(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        var removed = false
        let launcher = ServiceLauncher(approvals: approvals, runLaunchctl: { args in
            switch args.first {
            case "print": return removed ? (113, "") : (0, "\tpid = \(pid)\n")
            case "remove":
                if !removed { removed = true; kill(pid, SIGTERM) }
                return (0, "")
            case "bootstrap":
                aliveAtBootstrap = kill(pid, 0) == 0
                bootstrapped.fulfill()
                return (0, "")
            default: return (0, "")
            }
        })
        let store = ServiceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString)"),
                                 launcher: launcher, approvals: approvals)
        store.approveAndStart(entry())
        wait(for: [bootstrapped], timeout: 5)
        XCTAssertEqual(aliveAtBootstrap, false)
    }
}
