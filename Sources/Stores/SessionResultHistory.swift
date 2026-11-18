import Foundation
import SQLite3

struct SessionResultSource: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: String
    let agent: AgentSource
    let project: String?
    var sessionTitle: String?
    let receivedAt: Date

    var label: String {
        [agent.displayName, project].compactMap { $0 }.joined(separator: " · ")
    }

    func focusTarget(in sessions: [AgentSession]) -> AgentSession? {
        guard let session = sessions.first(where: { $0.id == sessionID && $0.agentSource == agent }) else { return nil }
        switch session.host {
        case .paseo, .codexDesktop:
            return session
        case .other:
            return nil
        case .terminal, .unknown:
            return session.focusAppBundleId != nil || session.terminalPid != nil || session.itermSessionId != nil
                ? session : nil
        }
    }
}

struct SessionResultReport: Equatable, Sendable {
    var source: SessionResultSource
    let markdown: String

    init(sessionID: String, agent: AgentSource, project: String?, sessionTitle: String? = nil, markdown: String) {
        self.init(source: SessionResultSource(id: UUID(), sessionID: sessionID, agent: agent,
                                             project: project, sessionTitle: sessionTitle, receivedAt: Date()),
                  markdown: markdown)
    }

    init(source: SessionResultSource, markdown: String) {
        self.source = source
        self.markdown = markdown
    }
}

actor SessionResultHistory {
    private struct DatabaseError: Error {
        let code: Int32
    }

    private let url: URL
    private var limit: Int
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, limit: Int) {
        self.url = url
        self.limit = limit
    }

    func append(_ report: SessionResultReport) throws {
        try withDatabase { db in
            try execute("BEGIN IMMEDIATE", db: db)
            do {
                try withStatement("""
                    INSERT INTO results (id, session_id, agent, project, session_title, received_at, markdown)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, db: db) { statement in
                    let source = report.source
                    try bind(source.id.uuidString, to: 1, in: statement)
                    try bind(source.sessionID, to: 2, in: statement)
                    try bind(source.agent.rawValue, to: 3, in: statement)
                    try bind(source.project.map(SecretRedactor.redact), to: 4, in: statement)
                    try bind(source.sessionTitle.map(SecretRedactor.redact), to: 5, in: statement)
                    try check(sqlite3_bind_double(statement, 6, source.receivedAt.timeIntervalSince1970))
                    try bind(SecretRedactor.redact(report.markdown), to: 7, in: statement)
                    try check(sqlite3_step(statement), expected: SQLITE_DONE)
                }
                try prune(db, limit: limit)
                try execute("COMMIT", db: db)
            } catch {
                try? execute("ROLLBACK", db: db)
                throw error
            }
        }
    }

    func setLimit(_ newLimit: Int) throws {
        try withDatabase { try prune($0, limit: newLimit) }
        limit = newLimit
    }

    func list() throws -> [SessionResultSource] {
        try withDatabase { db in
            try withStatement("""
                SELECT id, session_id, agent, project, session_title, received_at
                FROM results ORDER BY sequence DESC LIMIT ?
                """, db: db) { statement in
                try check(sqlite3_bind_int64(statement, 1, Int64(limit)))
                var results: [SessionResultSource] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    results.append(try source(in: statement))
                    status = sqlite3_step(statement)
                }
                try check(status, expected: SQLITE_DONE)
                return results
            }
        }
    }

    func record(id: UUID) throws -> SessionResultReport? {
        try withDatabase { db in
            try withStatement("""
                SELECT id, session_id, agent, project, session_title, received_at, markdown
                FROM results WHERE id = ?
                """, db: db) { statement in
                try bind(id.uuidString, to: 1, in: statement)
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return nil }
                try check(status, expected: SQLITE_ROW)
                return SessionResultReport(source: try source(in: statement), markdown: text(6, in: statement) ?? "")
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let created = fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            guard created else { throw DatabaseError(code: SQLITE_CANTOPEN) }
        }
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        try check(status)
        guard let db else { throw DatabaseError(code: SQLITE_CANTOPEN) }
        try check(sqlite3_busy_timeout(db, 3000))
        try execute("""
            CREATE TABLE IF NOT EXISTS results (
                sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL, agent TEXT NOT NULL, project TEXT, session_title TEXT,
                received_at REAL NOT NULL, markdown TEXT NOT NULL
            )
            """, db: db)
        return try body(db)
    }

    private func prune(_ db: OpaquePointer, limit: Int) throws {
        try withStatement("""
            DELETE FROM results WHERE sequence IN (
                SELECT sequence FROM results ORDER BY sequence DESC LIMIT -1 OFFSET ?
            )
            """, db: db) { statement in
            try check(sqlite3_bind_int64(statement, 1, Int64(limit)))
            try check(sqlite3_step(statement), expected: SQLITE_DONE)
        }
    }

    private func withStatement<T>(_ sql: String, db: OpaquePointer, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw DatabaseError(code: SQLITE_ERROR) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func source(in statement: OpaquePointer) throws -> SessionResultSource {
        guard let rawID = text(0, in: statement), let id = UUID(uuidString: rawID),
              let session = text(1, in: statement) else { throw DatabaseError(code: SQLITE_CORRUPT) }
        let agent = text(2, in: statement).flatMap(AgentSource.init(rawValue:)) ?? .unknown
        return SessionResultSource(id: id, sessionID: session, agent: agent,
                                   project: text(3, in: statement), sessionTitle: text(4, in: statement),
                                   receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)))
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        guard code == expected else { throw DatabaseError(code: code) }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index))
            return
        }
        let bytes = value.utf8CString
        let length = bytes.count - 1
        guard length <= Int(Int32.max) else { throw DatabaseError(code: SQLITE_TOOBIG) }
        try bytes.withUnsafeBufferPointer {
            try check(sqlite3_bind_text(statement, index, $0.baseAddress, Int32(length), Self.transient))
        }
    }

    private func text(_ index: Int32, in statement: OpaquePointer) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }
}
