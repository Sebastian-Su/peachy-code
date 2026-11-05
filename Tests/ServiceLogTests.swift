import XCTest
@testable import PeachyPet

final class ServiceLogTests: XCTestCase {
    private var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log") }
    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    /// S16: a log over 5 MB is cut back before the next run, keeping the newest part.
    func testLogIsCappedKeepingNewest() throws {
        var data = Data(repeating: UInt8(ascii: "a"), count: ServiceLog.maxBytes)
        data.append(Data("NEWEST\n".utf8))
        try data.write(to: url)
        ServiceLog.prepare(url)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, ServiceLog.maxBytes)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("NEWEST\n"))
    }

    /// X8: credentials in the log never reach the screen.
    func testTailIsRedactedAndLimited() throws {
        let lines = (1...500).map { "line \($0)" } + ["curl -H \"Authorization: Bearer sk-live-123456789\""]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = ServiceLog.tail(url, lines: 50)
        XCTAssertEqual(tail.split(separator: "\n").count, 50)
        XCTAssertFalse(tail.contains("sk-live-123456789"))
        XCTAssertTrue(tail.contains("Bearer <redacted>"))
    }

    func testMissingLogIsEmpty() {
        XCTAssertEqual(ServiceLog.tail(url, lines: 10), "")
    }
}
