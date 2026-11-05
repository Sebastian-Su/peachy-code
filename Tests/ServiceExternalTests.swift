import XCTest
@testable import PeachyPet

final class ServiceExternalTests: XCTestCase {
    private func entry(_ command: String, cwd: String? = nil, port: Int? = 11434) -> ServiceEntry {
        ServiceEntry(id: "x", name: "X", kind: .service, command: command, cwd: cwd, url: nil, port: port, env: [:], note: nil,
                     fileURL: URL(fileURLWithPath: "/tmp/x.json"), modifiedAt: nil)
    }
    private func listener(_ command: String, cwd: String = "/") -> PortListener {
        PortListener(pid: 900, command: command, cwd: cwd)
    }

    /// S10: started from a terminal or by an agent, still recognized.
    func testMatchesByCommandToken() {
        XCTAssertEqual(ServiceStatus.resolve(entry("ollama serve"), managedPID: nil, listener: listener("/opt/homebrew/bin/ollama serve")),
                       .external(pid: 900, command: "/opt/homebrew/bin/ollama serve"))
    }

    func testMatchesByWorkingDirectory() {
        let e = entry("conda run -n comfy python main.py --port 8188", cwd: "/Users/u/ComfyUI", port: 8188)
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: nil, listener: listener("python main.py --listen", cwd: "/Users/u/ComfyUI")),
                       .external(pid: 900, command: "python main.py --listen"))
    }

    /// /var is a symlink to /private/var; lsof reports the resolved path.
    func testWorkingDirectoryMatchResolvesSymlinks() {
        let e = entry("conda run -n comfy python main.py", cwd: "/var/tmp", port: 8188)
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: nil, listener: listener("python main.py", cwd: "/private/var/tmp")),
                       .external(pid: 900, command: "python main.py"))
    }

    /// S11, X2: something else on the port is never treated as ours.
    func testUnrelatedProcessOnPortIsBusyNotOurs() {
        let e = entry("conda run -n comfy python main.py", cwd: "/Users/u/ComfyUI", port: 8188)
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: nil, listener: listener("python -m http.server 8188", cwd: "/tmp")),
                       .portBusy(pid: 900, command: "python -m http.server 8188"))
    }

    /// Generic launcher words (python, node, npm…) alone are not a match.
    func testGenericWordsDoNotMatch() {
        let e = entry("npm run dev", cwd: "/Users/u/app", port: 3000)
        XCTAssertEqual(ServiceStatus.resolve(e, managedPID: nil, listener: listener("node server.js", cwd: "/Users/u/other")),
                       .portBusy(pid: 900, command: "node server.js"))
    }

    func testManagedWinsAndNoPortMeansLaunchdOnly() {
        XCTAssertEqual(ServiceStatus.resolve(entry("ollama serve"), managedPID: 77, listener: listener("ollama serve")), .running(pid: 77))
        XCTAssertEqual(ServiceStatus.resolve(entry("x", port: nil), managedPID: nil, listener: nil), .stopped)
        XCTAssertEqual(ServiceStatus.resolve(entry("ollama serve"), managedPID: nil, listener: nil), .stopped)
    }

    func testParsesLsofListeners() {
        let out = "p900\ncollama\nf5\nn127.0.0.1:11434\np901\ncnode\nf7\nn*:3000\nf8\nn[::1]:3001\n"
        XCTAssertEqual(PortListener.parseLsof(out), [11434: 900, 3000: 901, 3001: 901])
    }

    /// S12: TERM first, KILL only if still alive after the grace period.
    func testTerminateSendsTermThenKill() {
        var signals: [Int32] = []
        var alive = true
        ProcessTerminator.terminate(pid: 900, grace: 0.05,
                                    send: { _, sig in signals.append(sig) },
                                    isAlive: { _ in alive })
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        signals = []; alive = false
        ProcessTerminator.terminate(pid: 900, grace: 0.05, send: { _, sig in signals.append(sig) }, isAlive: { _ in alive })
        XCTAssertEqual(signals, [SIGTERM])
    }
}
