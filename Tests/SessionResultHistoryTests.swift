import XCTest
@testable import PeachyPet

final class SessionResultHistoryTests: XCTestCase {
    func testSQLiteKeepsNewestResultsAndPreservesSourceAndFullMarkdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("results.sqlite3")
        let history = SessionResultHistory(url: database, limit: 2)
        let old = report("old", "Old")
        let middle = report("middle", "Middle")
        let body = String(repeating: "# 报告\n\n- 한국어\n", count: 18_000)
        let newest = report("newest", body)

        for entry in [old, middle, newest] { try await history.append(entry) }
        let reopened = SessionResultHistory(url: database, limit: 2)
        let entries = try await reopened.list()
        XCTAssertEqual(entries.map(\.sessionID), ["newest", "middle"])
        XCTAssertEqual(entries[0].agent, .codex)
        XCTAssertEqual(entries[0].sessionTitle, "Session newest")
        let full = try await reopened.record(id: newest.source.id)
        XCTAssertEqual(full?.markdown, body)
        try await reopened.setLimit(1)
        let trimmed = try await reopened.list()
        XCTAssertEqual(trimmed.map(\.sessionID), ["newest"])
        let removed = try await reopened.record(id: middle.source.id)
        XCTAssertNil(removed)
    }

    @MainActor
    func testPreviewPausesAndExpiresWithoutRemovingHistory() async throws {
        let suite = "PeachyPetResultHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionResultStore(defaults: defaults, databaseURL: directory.appendingPathComponent("results.sqlite3"))
        let entry = report("source", "# Report")
        await store.add(entry, showPreview: true)
        let preview = try XCTUnwrap(store.preview)
        XCTAssertEqual(preview.remaining(at: preview.deadline!.addingTimeInterval(-30)), 30, accuracy: 0.01)
        store.setPreviewShortcutsHeld(true, at: preview.deadline!.addingTimeInterval(-12))
        store.setPreviewHovered(true, at: preview.deadline!.addingTimeInterval(-9))
        store.setPreviewShortcutsHeld(false, at: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(store.preview?.remaining(at: .distantFuture), 12)
        store.setPreviewHovered(false, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.preview?.deadline, Date(timeIntervalSince1970: 112))
        store.expirePreview(at: Date(timeIntervalSince1970: 111))
        XCTAssertNotNil(store.preview)
        store.expirePreview(at: Date(timeIntervalSince1970: 112))
        XCTAssertNil(store.preview)
        await store.refresh()
        XCTAssertEqual(store.entries.map(\.sessionID), ["source"])
    }

    @MainActor
    func testScheduledExpiryClosesTheBubbleAndKeepsAgentOnlyResultsInHistory() async throws {
        let suite = "PeachyPetResultHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionResultStore(defaults: defaults, databaseURL: directory.appendingPathComponent("results.sqlite3"),
                                       previewDuration: 0.1)
        let expiry = expectation(description: "Preview timer closes the bubble")
        store.onPreviewChange = {
            if store.preview == nil { expiry.fulfill() }
        }
        await store.add(report("popup", "# Popup"), showPreview: true)
        XCTAssertEqual(store.preview?.report.source.sessionID, "popup")
        await store.add(report("returned", "# Agent only"), showPreview: false)
        XCTAssertEqual(store.preview?.report.source.sessionID, "popup")
        await fulfillment(of: [expiry], timeout: 2)
        store.onPreviewChange = nil
        XCTAssertNil(store.preview)
        XCTAssertEqual(store.entries.map(\.sessionID), ["returned", "popup"])
    }

    @MainActor
    func testNumberedActionsOpenTheVisibleReportOrItsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionResultStore(databaseURL: directory.appendingPathComponent("results.sqlite3"))
        let entry = report("keyboard-session", "# Report")
        await store.add(entry, showPreview: true)

        store.perform(.readReport)
        XCTAssertEqual(store.navigation?.reportID, entry.source.id)
        XCTAssertNil(store.preview)
        await store.add(report("another-result", "# Another"), showPreview: true)
        store.perform(.history)
        XCTAssertNil(store.navigation?.reportID)
        XCTAssertNil(store.preview)
        XCTAssertEqual(store.entries.count, 2)
    }

    private func report(_ id: String, _ markdown: String) -> SessionResultReport {
        SessionResultReport(sessionID: id, agent: .codex, project: "Project",
                            sessionTitle: "Session \(id)", markdown: markdown)
    }
}
