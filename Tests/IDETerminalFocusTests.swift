import Foundation
import XCTest
@testable import PeachyPet

final class IDETerminalFocusTests: XCTestCase {
    func testCodexDesktopSessionOpensExactThreadDeepLink() {
        let threadId = "019f8008-7c42-71f3-b479-13be677e97e4"
        var session = AgentSession(
            id: threadId,
            projectDir: "/Users/test/project",
            projectName: "project",
            agentSource: .codex,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        )
        session.rawSource = "codex-desktop"

        var openedURL: URL?
        IDETerminalFocus.focusSession(session) { url in
            openedURL = url
            return true
        }

        XCTAssertEqual(openedURL?.absoluteString, "codex://threads/\(threadId)")
    }
    func testPaseoSessionOpensPaseoAgentInsteadOfCodexThread() throws {
        let threadId = "01a144a2-7eee-7de0-a2c1-0cdfcae827ab"
        let root = try makePaseoRoot(serverId: "srv_test", agents: [
            "13f0af73-3bfc-4245-84c4-636f7eaa07d3": threadId,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PaseoRegistry(root: root)

        var session = AgentSession(
            id: threadId, projectDir: "/Users/test/AIIG", projectName: "AIIG", agentSource: .codex,
            status: .active, eventCount: 1, startedAt: Date(), lastEventAt: Date()
        )
        session.rawSource = "codex-desktop"

        var openedURL: URL?
        IDETerminalFocus.focusSession(session, paseo: registry) { url in
            openedURL = url
            return true
        }

        XCTAssertEqual(openedURL?.absoluteString, "paseo://h/srv_test/agent/13f0af73-3bfc-4245-84c4-636f7eaa07d3")
    }

    func testRegistryMissesUnknownSessionAndMissingDirectory() throws {
        let root = try makePaseoRoot(serverId: "srv_test", agents: ["a1": "known-session"])
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNotNil(PaseoRegistry(root: root).agent(forSession: "known-session"))
        XCTAssertNil(PaseoRegistry(root: root).agent(forSession: "terminal-session"))
        XCTAssertNil(PaseoRegistry(root: root.appendingPathComponent("absent")).agent(forSession: "known-session"))
    }

    /// Writes a minimal ~/.paseo layout: server-id plus one record per agent id -> session id.
    private func makePaseoRoot(serverId: String, agents: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paseo-\(UUID().uuidString)")
        let project = root.appendingPathComponent("agents/Users-test-AIIG")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try serverId.write(to: root.appendingPathComponent("server-id"), atomically: true, encoding: .utf8)
        for (agentId, sessionId) in agents {
            let record: [String: Any] = [
                "id": agentId, "provider": "codex",
                "runtimeInfo": ["provider": "codex", "sessionId": sessionId],
            ]
            try JSONSerialization.data(withJSONObject: record)
                .write(to: project.appendingPathComponent("\(agentId).json"))
        }
        return root
    }
}

