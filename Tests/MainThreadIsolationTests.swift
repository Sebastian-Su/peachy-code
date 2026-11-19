import XCTest
@testable import PeachyPet

/// Disk, parsing and polling must not run on the main thread; only results reach it.
final class MainThreadIsolationTests: XCTestCase {
    private struct Probe: Encodable {
        let onMain: () -> Void
        func encode(to encoder: Encoder) throws {
            onMain()
            var container = encoder.singleValueContainer()
            try container.encode("x")
        }
    }

    func testBackgroundSaveEncodesOffTheMainThread() {
        let filename = "isolation-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(at: LocalStorage.appSupportDir.appendingPathComponent(filename)) }
        var encodedOnMain: Bool?
        LocalStorage.saveInBackground(Probe(onMain: { encodedOnMain = Thread.isMainThread }), to: filename)
        LocalStorage.flush()
        XCTAssertEqual(encodedOnMain, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalStorage.appSupportDir.appendingPathComponent(filename).path))
    }

    func testCodexLogsArePolledOnTheMonitorQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "test.codex-monitor")
        let monitor = CodexSessionMonitor(rootURL: root, pollInterval: 0.05, queue: queue)
        let delivered = expectation(description: "event delivered")
        var deliveredOnMain: Bool?
        monitor.onEventReceived = { _ in
            deliveredOnMain = Thread.isMainThread
            delivered.fulfill()
        }
        queue.sync { monitor.start(bootstrapRecentFiles: false) }
        XCTAssertTrue(monitor.isRunning)
        defer { queue.sync { monitor.stop() } }

        try (#"{"type":"session_meta","payload":{"id":"019cd686-3b91-78a1-9356-21b475548352","cwd":"/tmp/p","source":"cli"}}"# + "\n")
            .write(to: root.appendingPathComponent("rollout-2026-11-20T00-00-00-019cd686-3b91-78a1-9356-21b475548352.jsonl"),
                   atomically: true, encoding: .utf8)
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(deliveredOnMain, false)
    }
}
