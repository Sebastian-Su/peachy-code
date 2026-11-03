import XCTest
@testable import PeachyPet

final class AgentOverviewTests: XCTestCase {
    private func session(_ engine: AgentSource, _ host: SessionHost, active: Bool = false) -> AgentSession {
        var s = AgentSession(id: UUID().uuidString, projectDir: nil, projectName: "p", agentSource: engine,
                             status: active ? .active : .ended, eventCount: 1, startedAt: Date(), lastEventAt: Date())
        s.host = host
        return s
    }

    func testCountsSessionsAndHostsPerEngine() {
        let sessions = [
            session(.codex, .paseo(agentId: "a"), active: true),
            session(.codex, .paseo(agentId: "b")),
            session(.codex, .codexDesktop),
            session(.codex, .other(originator: "baocut")),
            session(.claudeCode, .terminal, active: true),
            session(.claudeCode, .unknown),
        ]
        let overview = AgentOverview.build(sessions: sessions, installed: [.claudeCode: true, .codex: false, .copilot: false])

        XCTAssertEqual(overview.map(\.engine), [.claudeCode, .codex, .copilot])
        let codex = overview[1]
        XCTAssertEqual(codex.sessionCount, 4)
        XCTAssertEqual(codex.activeCount, 1)
        XCTAssertFalse(codex.isInstalled)
        XCTAssertEqual(codex.hosts, [.init(kind: .paseo, count: 2), .init(kind: .codexDesktop, count: 1), .init(kind: .other, count: 1)])
        let claude = overview[0]
        XCTAssertEqual(claude.hosts, [.init(kind: .terminal, count: 1), .init(kind: .unknown, count: 1)])
        XCTAssertTrue(claude.isInstalled)
        XCTAssertEqual(overview[2].sessionCount, 0)
    }

    /// Reading install status must never write the agents' config files (N3).
    func testReadingInstallStatusLeavesConfigUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-overview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hooks = dir.appendingPathComponent("hooks.json")
        let original = Data(#"{"hooks":{}}"#.utf8)
        try original.write(to: hooks)
        let before = try FileManager.default.attributesOfItem(atPath: hooks.path)[.modificationDate] as? Date

        XCTAssertFalse(CodexHookInstaller.isRegistered(hooksJSONPath: hooks.path))

        XCTAssertEqual(try Data(contentsOf: hooks), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: hooks.path)[.modificationDate] as? Date, before)
    }
}
