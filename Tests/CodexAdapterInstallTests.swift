import XCTest
@testable import PeachyPet

final class CodexAdapterInstallTests: XCTestCase {
    // 引擎由投递方（peachy_client）决定，是分发依据 — 不再从 source 字符串推断
    func testEngineComesFromClientTag() {
        let codex = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1", cwd: nil, client: "codex-cli")
        let claude = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1", cwd: nil, source: "startup")
        let copilot = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1", cwd: nil, client: "copilot")
        XCTAssertEqual(codex.agentSource, .codex)
        XCTAssertEqual(claude.agentSource, .claudeCode)
        XCTAssertEqual(copilot.agentSource, .copilot)
    }

    /// The hook script now writes peachy_client and leaves Codex's own source untouched.
    func testDecodedHookPayloadKeepsSourceAndReadsClient() throws {
        let json = #"{"hook_event_name":"SessionStart","session_id":"s","source":"startup","peachy_client":"codex-cli"}"#
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.agentSource, .codex)
        XCTAssertEqual(event.startReason, "startup")
    }

    /// events.json and not-yet-rewritten scripts carry the tag in source.
    func testDecodedLegacyPayloadReadsClientFromSource() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s","source":"codex-cli"}"#
        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.agentSource, .codex)
    }

    func testPermissionRequestRoutesToPermissionAndSessionPipelines() {
        let adapter = CodexAdapter()
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "waiting-session",
            cwd: "/tmp",
            client: "codex-desktop"
        )
        var permissionEvent: AgentEvent?
        var sessionEvent: AgentEvent?
        adapter.onPermissionRequest = { received, _ in permissionEvent = received }
        adapter.onEvent = { received in sessionEvent = received }

        adapter.route(event)

        XCTAssertEqual(permissionEvent?.id, event.id)
        XCTAssertEqual(sessionEvent?.id, event.id)
    }
}
