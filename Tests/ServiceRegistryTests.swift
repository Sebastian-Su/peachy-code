import XCTest
@testable import PeachyPet

final class ServiceRegistryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent(name))
    }

    func testIdRules() {
        for ok in ["comfyui", "git-pull-all", "a1", "ollama-2"] { XCTAssertTrue(ServiceRegistry.isValidId(ok), ok) }
        for bad in ["ComfyUI", "comfy_ui", "-x", "a b", "", "x.y", "../x"] { XCTAssertFalse(ServiceRegistry.isValidId(bad), bad) }
    }

    func testParsesFullAndMinimalEntries() throws {
        try write("comfyui.json", #"{"schema":1,"name":"ComfyUI","kind":"service","command":"python main.py","cwd":"~/x","url":"http://127.0.0.1:8188","port":8188,"env":{"A":"1"},"note":"n"}"#)
        try write("pull.json", #"{"schema":1,"name":"拉取","kind":"task","command":"./a.sh"}"#)
        let items = ServiceRegistry.load(from: dir)
        XCTAssertEqual(items.map(\.id), ["comfyui", "pull"])
        guard case .valid(let c) = items[0].state else { return XCTFail() }
        XCTAssertEqual(c.kind, .service); XCTAssertEqual(c.port, 8188); XCTAssertEqual(c.env, ["A": "1"])
        XCTAssertEqual(c.cwd, NSHomeDirectory() + "/x")
        guard case .valid(let p) = items[1].state else { return XCTFail() }
        XCTAssertEqual(p.kind, .task); XCTAssertNil(p.port)
    }

    func testBadFilesAreIsolatedWithReasons() throws {
        try write("good.json", #"{"schema":1,"name":"G","kind":"service","command":"x"}"#)
        try write("broken.json", "{not json")
        try write("missing.json", #"{"schema":1,"name":"M","kind":"service"}"#)
        try write("badkind.json", #"{"schema":1,"name":"K","kind":"daemon","command":"x"}"#)
        try write("future.json", #"{"schema":2,"name":"F","kind":"service","command":"x"}"#)
        try write("Bad_Name.json", #"{"schema":1,"name":"B","kind":"service","command":"x"}"#)
        try write("notes.txt", "ignored")
        let items = Dictionary(uniqueKeysWithValues: ServiceRegistry.load(from: dir).map { ($0.id, $0.state) })
        XCTAssertEqual(items.count, 6)
        if case .valid = items["good"]! {} else { XCTFail("good should load") }
        for id in ["broken", "missing", "badkind", "future", "Bad_Name"] {
            guard case .invalid(let reason) = items[id]! else { return XCTFail("\(id) should be invalid") }
            XCTAssertFalse(reason.message.isEmpty)
        }
    }

    func testUnknownFieldsAreIgnored() throws {
        try write("x.json", #"{"schema":1,"name":"X","kind":"service","command":"x","future_field":{"a":1}}"#)
        guard case .valid = ServiceRegistry.load(from: dir)[0].state else { return XCTFail() }
    }

    func testMissingDirectoryIsEmptyNotACrash() {
        XCTAssertEqual(ServiceRegistry.load(from: dir.appendingPathComponent("nope")).count, 0)
    }
}

final class ServiceStoreWatchTests: XCTestCase {
    /// S5: adding and removing a file shows up within about a second, no restart.
    func testWatchingPicksUpAddAndRemoveWithinASecond() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ServiceStore(directory: dir)
        store.startWatching()
        defer { store.stopWatching() }
        XCTAssertEqual(store.items.count, 0)

        try Data(#"{"schema":1,"name":"X","kind":"service","command":"x"}"#.utf8).write(to: dir.appendingPathComponent("x.json"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(store.items.map(\.id), ["x"])

        try FileManager.default.removeItem(at: dir.appendingPathComponent("x.json"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(store.items.count, 0)
    }

    /// Nothing is polled while the page is closed (S17).
    func testNoWatchingAfterStop() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ServiceStore(directory: dir)
        store.startWatching(); store.stopWatching()
        try Data(#"{"schema":1,"name":"X","kind":"service","command":"x"}"#.utf8).write(to: dir.appendingPathComponent("x.json"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(store.items.count, 0)
    }
}
