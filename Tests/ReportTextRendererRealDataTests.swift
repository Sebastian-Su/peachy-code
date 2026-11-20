import SQLite3
import XCTest
@testable import PeachyPet

/// Opt-in: renders every saved report. Run with PEACHY_REAL_RESULTS=<path to session-results.sqlite3>.
final class ReportTextRendererRealDataTests: XCTestCase {
    func testRendersEverySavedReport() throws {
        guard let path = ProcessInfo.processInfo.environment["PEACHY_REAL_RESULTS"] else { throw XCTSkip("no data") }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "select markdown from results", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var durations: [Double] = []
        var chars = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let markdown = String(cString: sqlite3_column_text(statement, 0))
            let start = Date()
            let rendered = ReportTextRenderer.render(markdown)
            durations.append(Date().timeIntervalSince(start) * 1000)
            chars += markdown.count
            XCTAssertFalse(rendered.string.isEmpty || rendered.string.contains("|---"), String(markdown.prefix(60)))
        }
        durations.sort()
        print(String(format: "REAL reports=%d chars=%d p50=%.1fms max=%.1fms", durations.count, chars,
                     durations[durations.count / 2], durations.last ?? 0))
    }
}
