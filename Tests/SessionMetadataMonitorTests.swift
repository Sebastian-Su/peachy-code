import XCTest
@testable import PeachyPet

// MARK: - Parser Tests

final class SessionMetadataMonitorParserTests: XCTestCase {

    // MARK: Claude transcript parsing

    func testClaudeLastCustomTitleWins() {
        let lines = [
            #"{"type":"custom-title","customTitle":"旧标题","sessionId":"claude-1"}"#,
            #"{"type":"custom-title","customTitle":"新标题","sessionId":"claude-1"}"#,
        ]
        let result = ClaudeTranscriptParser.parseTitle(lines: lines, sessionId: "claude-1")
        XCTAssertEqual(result, "新标题")
    }

    func testClaudeCustomTitleIgnoresOtherSessionIds() {
        let lines = [
            #"{"type":"custom-title","customTitle":"他人标题","sessionId":"claude-2"}"#,
            #"{"type":"custom-title","customTitle":"我的标题","sessionId":"claude-1"}"#,
        ]
        let result = ClaudeTranscriptParser.parseTitle(lines: lines, sessionId: "claude-1")
        XCTAssertEqual(result, "我的标题")
    }

    func testClaudePromptFallbackUsesFirstPromptOnly() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"第一条"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"第二条"}]}}"#,
        ]
        let result = ClaudeTranscriptParser.parseFirstPrompt(lines: lines)
        XCTAssertEqual(result, "第一条")
    }

    func testClaudePromptFallbackSkipsWhitespaceOnlyEntries() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"   "}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"实际内容"}]}}"#,
        ]
        let result = ClaudeTranscriptParser.parseFirstPrompt(lines: lines)
        XCTAssertEqual(result, "实际内容")
    }

    func testClaudeMalformedLineIsSkipped() {
        let lines = [
            "not-json",
            #"{"type":"custom-title","customTitle":"有效标题","sessionId":"claude-1"}"#,
        ]
        let result = ClaudeTranscriptParser.parseTitle(lines: lines, sessionId: "claude-1")
        XCTAssertEqual(result, "有效标题")
    }

    // MARK: Codex session_index parsing

    func testCodexLastThreadNameWinsForSameId() {
        let lines = [
            #"{"id":"codex-1","thread_name":"旧标题","updated_at":"2026-07-24T10:00:00Z"}"#,
            #"{"id":"codex-1","thread_name":"新标题","updated_at":"2026-07-24T10:01:00Z"}"#,
        ]
        let result = CodexSessionIndexParser.parseThreadName(lines: lines, sessionId: "codex-1")
        XCTAssertEqual(result, "新标题")
    }

    func testCodexThreadIdsDoNotCrossWire() {
        let lines = [
            #"{"id":"codex-1","thread_name":"session1标题","updated_at":"2026-07-24T10:00:00Z"}"#,
            #"{"id":"codex-2","thread_name":"session2标题","updated_at":"2026-07-24T10:01:00Z"}"#,
        ]
        let result1 = CodexSessionIndexParser.parseThreadName(lines: lines, sessionId: "codex-1")
        let result2 = CodexSessionIndexParser.parseThreadName(lines: lines, sessionId: "codex-2")
        XCTAssertEqual(result1, "session1标题")
        XCTAssertEqual(result2, "session2标题")
    }

    func testCodexMalformedLineIsSkipped() {
        let lines = [
            "not-json",
            #"{"id":"codex-1","thread_name":"有效标题","updated_at":"2026-07-24T10:00:00Z"}"#,
        ]
        let result = CodexSessionIndexParser.parseThreadName(lines: lines, sessionId: "codex-1")
        XCTAssertEqual(result, "有效标题")
    }

    // MARK: Codex global state parsing

    func testCodexDesktopProjectAssignmentMapsName() {
        let json = """
        {
          "thread-project-assignments": {
            "codex-1": { "projectId": "proj-abc" }
          },
          "local-projects": {
            "proj-abc": { "name": "namiwork-core" }
          }
        }
        """
        let result = CodexGlobalStateParser.parseProjectName(json: json, sessionId: "codex-1")
        XCTAssertEqual(result, "namiwork-core")
    }

    func testCodexDesktopProjectAssignmentMissingSessionReturnsNil() {
        let json = """
        {
          "thread-project-assignments": {},
          "local-projects": {
            "proj-abc": { "name": "namiwork-core" }
          }
        }
        """
        let result = CodexGlobalStateParser.parseProjectName(json: json, sessionId: "codex-1")
        XCTAssertNil(result)
    }

    func testMalformedGlobalStatePreservesNoUpdate() {
        let malformed = "not-json-at-all"
        let result = CodexGlobalStateParser.parseProjectName(json: malformed, sessionId: "codex-1")
        XCTAssertNil(result)
    }

    func testGlobalStateWithMissingProjectIdReturnsNil() {
        let json = """
        {
          "thread-project-assignments": {
            "codex-1": {}
          },
          "local-projects": {
            "proj-abc": { "name": "namiwork-core" }
          }
        }
        """
        let result = CodexGlobalStateParser.parseProjectName(json: json, sessionId: "codex-1")
        XCTAssertNil(result)
    }

    func testGlobalStateWithUnknownProjectIdReturnsNil() {
        let json = """
        {
          "thread-project-assignments": {
            "codex-1": { "projectId": "proj-unknown" }
          },
          "local-projects": {
            "proj-abc": { "name": "namiwork-core" }
          }
        }
        """
        let result = CodexGlobalStateParser.parseProjectName(json: json, sessionId: "codex-1")
        XCTAssertNil(result)
    }

    func testGlobalStateEmptyProjectNameReturnsNil() {
        let json = """
        {
          "thread-project-assignments": {
            "codex-1": { "projectId": "proj-abc" }
          },
          "local-projects": {
            "proj-abc": { "name": "" }
          }
        }
        """
        let result = CodexGlobalStateParser.parseProjectName(json: json, sessionId: "codex-1")
        XCTAssertNil(result)
    }
}

// MARK: - Monitor Lifecycle Tests

@MainActor
final class SessionMetadataMonitorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMetadataMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeTranscriptPath(name: String = "transcript.jsonl") -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func write(lines: [String], to url: URL) throws {
        let content = lines.map { $0 + "\n" }.joined()
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(lines: [String], to url: URL) throws {
        let content = lines.map { $0 + "\n" }.joined()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(content.utf8))
            handle.closeFile()
        } else {
            try content.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    private func makeSession(
        id: String,
        transcriptPath: URL? = nil,
        source: AgentSource = .claudeCode
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectDir: tempDir.path,
            projectName: "test-project",
            agentSource: source,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date(),
            transcriptPath: transcriptPath?.path
        )
    }

    // MARK: Monitor reads Claude rename after start

    func testMonitorReadsClaudeRenameAfterStart() async throws {
        let transcriptURL = makeTranscriptPath(name: "claude-1.jsonl")
        try write(lines: [
            #"{"type":"custom-title","customTitle":"初始标题","sessionId":"claude-1"}"#,
        ], to: transcriptURL)

        let session = makeSession(id: "claude-1", transcriptPath: transcriptURL)

        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [session])
        defer { monitor.stop() }

        // Initial scan should pick up existing title
        let initialUpdate = updates.first(where: { $0.sessionId == "claude-1" })
        XCTAssertEqual(initialUpdate?.sessionTitle, "初始标题", "Initial scan must pick up existing custom-title")

        // Append a rename after start
        updates.removeAll()
        try append(lines: [
            #"{"type":"custom-title","customTitle":"新标题","sessionId":"claude-1"}"#,
        ], to: transcriptURL)

        let exp = expectation(description: "rename detected")
        let deadline = Date().addingTimeInterval(1.0)
        var found = false
        while Date() < deadline && !found {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if updates.contains(where: { $0.sessionId == "claude-1" && $0.sessionTitle == "新标题" }) {
                found = true
                exp.fulfill()
            }
        }
        if !found { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertTrue(
            updates.contains(where: { $0.sessionId == "claude-1" && $0.sessionTitle == "新标题" }),
            "Monitor must emit updated title after append"
        )
    }

    // MARK: Monitor reads Codex thread rename after start

    func testMonitorReadsCodexThreadRenameAfterStart() async throws {
        // Monitor looks at homeDirectory/.codex/session_index.jsonl
        let codexDir = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let sessionIndexURL = codexDir.appendingPathComponent("session_index.jsonl")
        try write(lines: [
            #"{"id":"codex-1","thread_name":"初始名","updated_at":"2026-07-24T10:00:00Z"}"#,
        ], to: sessionIndexURL)

        let session = makeSession(id: "codex-1", source: .codex)
        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [session])
        defer { monitor.stop() }

        let initialUpdate = updates.first(where: { $0.sessionId == "codex-1" })
        XCTAssertEqual(initialUpdate?.sessionTitle, "初始名")

        updates.removeAll()
        try append(lines: [
            #"{"id":"codex-1","thread_name":"新名字","updated_at":"2026-07-24T10:01:00Z"}"#,
        ], to: sessionIndexURL)

        let exp = expectation(description: "codex rename detected")
        let deadline = Date().addingTimeInterval(1.0)
        var found = false
        while Date() < deadline && !found {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if updates.contains(where: { $0.sessionId == "codex-1" && $0.sessionTitle == "新名字" }) {
                found = true
                exp.fulfill()
            }
        }
        if !found { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertTrue(
            updates.contains(where: { $0.sessionId == "codex-1" && $0.sessionTitle == "新名字" }),
            "Monitor must emit updated codex thread name"
        )
    }

    // MARK: Monitor reads Desktop project name after global state replacement

    func testMonitorReadsDesktopProjectNameAfterGlobalStateReplacement() async throws {
        // Monitor looks at homeDirectory/.codex/.codex-global-state.json
        let codexDir = tempDir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let globalStateURL = codexDir.appendingPathComponent(".codex-global-state.json")
        let initial = """
        {
          "thread-project-assignments": {
            "codex-2": { "projectId": "proj-1" }
          },
          "local-projects": {
            "proj-1": { "name": "old-project" }
          }
        }
        """
        try initial.write(to: globalStateURL, atomically: true, encoding: .utf8)

        let session = makeSession(id: "codex-2", source: .codex)
        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [session])
        defer { monitor.stop() }

        // Initial scan
        let initialUpdate = updates.first(where: { $0.sessionId == "codex-2" })
        XCTAssertEqual(initialUpdate?.projectDisplayName, "old-project")

        // Replace global state atomically
        updates.removeAll()
        let updated = """
        {
          "thread-project-assignments": {
            "codex-2": { "projectId": "proj-2" }
          },
          "local-projects": {
            "proj-2": { "name": "new-project" }
          }
        }
        """
        try updated.write(to: globalStateURL, atomically: true, encoding: .utf8)

        let exp = expectation(description: "project name updated")
        let deadline = Date().addingTimeInterval(1.0)
        var found = false
        while Date() < deadline && !found {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if updates.contains(where: { $0.sessionId == "codex-2" && $0.projectDisplayName == "new-project" }) {
                found = true
                exp.fulfill()
            }
        }
        if !found { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertTrue(
            updates.contains(where: { $0.sessionId == "codex-2" && $0.projectDisplayName == "new-project" }),
            "Monitor must pick up replaced global state"
        )
    }

    // MARK: Monitor stops without further updates

    func testMonitorStopsWithoutFurtherUpdates() throws {
        let transcriptURL = makeTranscriptPath(name: "claude-stop.jsonl")
        try write(lines: [
            #"{"type":"custom-title","customTitle":"停止前标题","sessionId":"stop-1"}"#,
        ], to: transcriptURL)

        let session = makeSession(id: "stop-1", transcriptPath: transcriptURL)
        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [session])

        // Allow initial scan
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        monitor.stop()
        let countAfterStop = updates.count

        // Append after stop — should not trigger more updates
        try append(lines: [
            #"{"type":"custom-title","customTitle":"停止后标题","sessionId":"stop-1"}"#,
        ], to: transcriptURL)

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(updates.count, countAfterStop, "No updates must arrive after stop()")
    }

    // MARK: Monitor only processes active sessions

    func testMonitorOnlyProcessesActiveSessions() throws {
        let transcriptURL = makeTranscriptPath(name: "inactive.jsonl")
        try write(lines: [
            #"{"type":"custom-title","customTitle":"inactive标题","sessionId":"inactive-1"}"#,
        ], to: transcriptURL)

        // Pass no sessions to start
        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [])
        defer { monitor.stop() }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(
            updates.filter { $0.sessionId == "inactive-1" }.isEmpty,
            "Monitor must not emit updates for sessions not in activeSessions"
        )
    }

    // MARK: Malformed transcript yields no update

    func testMalformedTranscriptYieldsNoUpdate() throws {
        let transcriptURL = makeTranscriptPath(name: "malformed.jsonl")
        try write(lines: [
            "this is not json at all",
            "{broken",
        ], to: transcriptURL)

        let session = makeSession(id: "malformed-1", transcriptPath: transcriptURL)
        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [session])
        defer { monitor.stop() }

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(
            updates.filter { $0.sessionId == "malformed-1" }.isEmpty,
            "Malformed transcript must not produce any update"
        )
    }

    // MARK: Truncation resets offset and rereads from byte zero

    func testTranscriptTruncationRereadsFromByteZero() async throws {
        let transcriptURL = makeTranscriptPath(name: "truncate.jsonl")
        try write(lines: [
            #"{"type":"custom-title","customTitle":"原始标题","sessionId":"trunc-1"}"#,
        ], to: transcriptURL)

        let session = makeSession(id: "trunc-1", transcriptPath: transcriptURL)
        var updates: [SessionMetadataUpdate] = []
        let monitor = SessionMetadataMonitor(
            homeDirectory: tempDir.path,
            pollInterval: 0.01,
            onUpdate: { updates.append($0) }
        )
        monitor.start(activeSessions: [session])
        defer { monitor.stop() }

        // Wait for initial scan
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(updates.contains(where: { $0.sessionId == "trunc-1" && $0.sessionTitle == "原始标题" }))

        updates.removeAll()
        // Atomically replace (truncate + rewrite) the file
        try write(lines: [
            #"{"type":"custom-title","customTitle":"截断后新标题","sessionId":"trunc-1"}"#,
        ], to: transcriptURL)

        let exp = expectation(description: "truncation reread")
        let deadline = Date().addingTimeInterval(1.0)
        var found = false
        while Date() < deadline && !found {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if updates.contains(where: { $0.sessionId == "trunc-1" && $0.sessionTitle == "截断后新标题" }) {
                found = true
                exp.fulfill()
            }
        }
        if !found { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertTrue(
            updates.contains(where: { $0.sessionId == "trunc-1" && $0.sessionTitle == "截断后新标题" }),
            "After truncation, monitor must reread from byte zero and emit new title"
        )
    }
}
