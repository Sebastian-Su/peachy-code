import XCTest
@testable import PeachyPet

final class ClaudeEventAssistantTests: XCTestCase {
    func testAssistantDisplayNameDefaultsToClaude() {
        let event = AgentEvent(hookEventName: HookEventType.sessionStart.rawValue)
        XCTAssertEqual(event.assistantDisplayName, "Claude Code")
    }

    func testAssistantDisplayNameDetectsCodexCLI() {
        let event = AgentEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            client: "codex-cli"
        )
        XCTAssertEqual(event.assistantDisplayName, "Codex")
    }

    /// A Codex Desktop rollout says source "vscode"; the engine comes from the poller's tag.
    func testAssistantDisplayNameDetectsCodexDesktop() {
        let event = AgentEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            source: "vscode",
            client: AgentEvent.codexJSONLClient,
            originator: "Codex Desktop"
        )
        XCTAssertEqual(event.assistantDisplayName, "Codex")
    }
}
