import XCTest
@testable import PeachyPet

final class ServiceApprovalTests: XCTestCase {
    private func entry(command: String = "ollama serve", cwd: String? = "/tmp", env: [String: String] = ["A": "1"],
                       name: String = "Ollama", url: String? = "http://x", note: String? = nil) -> ServiceEntry {
        ServiceEntry(id: "ollama", name: name, kind: .service, command: command, cwd: cwd, url: url.flatMap(URL.init(string:)),
                     port: 11434, env: env, note: note, fileURL: URL(fileURLWithPath: "/tmp/ollama.json"), modifiedAt: nil)
    }

    /// S20: only command, cwd and env decide whether a re-confirm is needed.
    func testFingerprintCoversOnlyWhatRuns() {
        let base = ServiceApproval.fingerprint(entry())
        XCTAssertNotEqual(base, ServiceApproval.fingerprint(entry(command: "ollama serve; rm -rf ~")))
        XCTAssertNotEqual(base, ServiceApproval.fingerprint(entry(cwd: "/")))
        XCTAssertNotEqual(base, ServiceApproval.fingerprint(entry(env: ["A": "2"])))
        XCTAssertEqual(base, ServiceApproval.fingerprint(entry(name: "Renamed", url: "http://y", note: "n")))
    }

    func testChangedFieldsAreNamed() {
        let store = ServiceApproval(defaults: UserDefaults(suiteName: "approval-\(UUID().uuidString)")!)
        XCTAssertEqual(store.status(of: entry()), .neverApproved)
        store.approve(entry())
        XCTAssertEqual(store.status(of: entry()), .approved)
        XCTAssertEqual(store.status(of: entry(name: "X", note: "y")), .approved)
        XCTAssertEqual(store.status(of: entry(command: "evil", env: [:])), .changed([.command, .env]))
    }

    /// S19: approvals live in PeachyPet's own storage and survive a new instance.
    func testApprovalPersistsAcrossInstances() {
        let suite = "approval-\(UUID().uuidString)"
        ServiceApproval(defaults: UserDefaults(suiteName: suite)!).approve(entry())
        XCTAssertEqual(ServiceApproval(defaults: UserDefaults(suiteName: suite)!).status(of: entry()), .approved)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }
}

final class ServiceLauncherTests: XCTestCase {
    private func entry(kind: ServiceEntry.Kind = .service) -> ServiceEntry {
        ServiceEntry(id: "comfyui", name: "ComfyUI", kind: kind, command: "python main.py --port 8188", cwd: "/tmp/comfy",
                     url: nil, port: 8188, env: ["HF_HOME": "/tmp/hf"], note: nil,
                     fileURL: URL(fileURLWithPath: "/tmp/comfyui.json"), modifiedAt: nil)
    }

    /// S7, S9, X4: login shell, no RunAtLoad/KeepAlive, logs to the service log.
    func testJobDefinitionRunsOnceThroughLoginShell() {
        let job = ServiceLauncher.jobDefinition(for: entry(), shell: "/bin/zsh", logURL: URL(fileURLWithPath: "/tmp/comfyui.log"))
        XCTAssertEqual(job["Label"] as? String, "com.peachypet.service.comfyui")
        XCTAssertEqual(job["ProgramArguments"] as? [String], ["/bin/zsh", "-lc", "python main.py --port 8188"])
        XCTAssertEqual(job["WorkingDirectory"] as? String, "/tmp/comfy")
        XCTAssertEqual(job["StandardOutPath"] as? String, "/tmp/comfyui.log")
        XCTAssertEqual(job["StandardErrorPath"] as? String, "/tmp/comfyui.log")
        XCTAssertEqual((job["EnvironmentVariables"] as? [String: String])?["HF_HOME"], "/tmp/hf")
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertNil(job["KeepAlive"])
        XCTAssertEqual(job["AbandonProcessGroup"] as? Bool, false)
    }

    /// X1: launching an unapproved or changed command is refused, nothing is submitted.
    func testUnapprovedCommandIsNeverSubmitted() throws {
        var submitted: [String] = []
        let approvals = ServiceApproval(defaults: UserDefaults(suiteName: "launch-\(UUID().uuidString)")!)
        let launcher = ServiceLauncher(approvals: approvals, runLaunchctl: { args in submitted.append(args.joined(separator: " ")); return (0, "") })
        XCTAssertThrowsError(try launcher.start(entry())) { XCTAssertEqual($0 as? ServiceLauncher.LaunchError, .needsApproval) }
        XCTAssertTrue(submitted.isEmpty)

        approvals.approve(entry())
        try launcher.start(entry())
        XCTAssertEqual(submitted.filter { $0.hasPrefix("bootstrap") }.count, 1)
        XCTAssertTrue(submitted.last!.hasPrefix("bootstrap gui/"))
    }

    /// S9: stop removes the job so nothing lingers.
    func testStopRemovesTheJob() throws {
        var calls: [[String]] = []
        let launcher = ServiceLauncher(approvals: ServiceApproval(defaults: UserDefaults(suiteName: "stop-\(UUID().uuidString)")!),
                                       runLaunchctl: { calls.append($0); return (0, "") })
        launcher.stop(id: "comfyui")
        XCTAssertEqual(calls.last?.first, "remove")
        XCTAssertEqual(calls.last?.last, "com.peachypet.service.comfyui")
    }
}

final class ServiceRunStateTests: XCTestCase {
    private func entry() -> ServiceEntry {
        ServiceEntry(id: "x", name: "X", kind: .service, command: "c", cwd: nil, url: nil, port: nil, env: [:], note: nil,
                     fileURL: URL(fileURLWithPath: "/tmp/x.json"), modifiedAt: nil)
    }

    /// X5: refreshing status only reads; it never starts anything.
    func testRefreshOnlyReads() {
        var calls: [[String]] = []
        let launcher = ServiceLauncher(approvals: ServiceApproval(defaults: UserDefaults(suiteName: "rs-\(UUID().uuidString)")!),
                                       runLaunchctl: { calls.append($0); return (113, "") })
        let state = ServiceRunState.read(entry(), launcher: launcher)
        XCTAssertEqual(state, .stopped)
        XCTAssertTrue(calls.allSatisfy { $0.first == "print" }, "\(calls)")
    }

    func testRunningWhenLaunchdReportsPid() {
        let launcher = ServiceLauncher(approvals: ServiceApproval(defaults: UserDefaults(suiteName: "rs-\(UUID().uuidString)")!),
                                       runLaunchctl: { _ in (0, "\tstate = running\n\tpid = 4242\n") })
        XCTAssertEqual(ServiceRunState.read(entry(), launcher: launcher), .running(pid: 4242))
    }
}
