import XCTest
@testable import PeachyPet

final class AgentEventTitleMetadataTests: XCTestCase {
    func testAgentEventDecodesUserPrompt() throws {
        let json = """
        {
          "hook_event_name": "UserPromptSubmit",
          "session_id": "claude-1",
          "prompt": "解决 release 分支冲突"
        }
        """

        let event = try JSONDecoder().decode(AgentEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.prompt, "解决 release 分支冲突")
    }
}
