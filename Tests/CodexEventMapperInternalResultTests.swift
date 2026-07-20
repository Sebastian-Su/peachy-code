import XCTest
@testable import PeachyPet

final class CodexEventMapperInternalResultTests: XCTestCase {
    // Helper to parse a task_complete JSONL line
    private func parseLine(lastMessage: String, turnId: String = "t1") -> [AgentEvent] {
        let payload: [String: Any] = [
            "type": "task_complete",
            "last_agent_message": lastMessage,
            "turn_id": turnId,
        ]
        let record: [String: Any] = [
            "type": "event_msg",
            "session_id": "s1",
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else {
            XCTFail("Could not serialize test record")
            return []
        }
        let context = CodexSessionContext(sessionId: "s1", cwd: "/tmp", source: "codex-cli", originator: nil, toolNamesByCallId: [:])
        return CodexEventMapper.parse(line: line, fileURL: URL(fileURLWithPath: "/tmp/s1.jsonl"), context: context).events
    }

    // 1. Approval-allow schema → internalResult
    func testApprovalAllowEmitsInternalResult() {
        let json = #"{"outcome":"allow","risk_level":"low","user_authorization":"explicit","rationale":"safe"}"#
        let events = parseLine(lastMessage: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .internalResult)
        XCTAssertEqual(events[0].taskId, "t1")
        XCTAssertFalse(events.contains(where: { $0.eventType == .stop }), "Stop must not be emitted")
    }

    // 2. Approval-deny schema → internalResult
    func testApprovalDenyEmitsInternalResult() {
        let json = #"{"outcome":"deny","rationale":"blocked"}"#
        let events = parseLine(lastMessage: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .internalResult)
    }

    // 3. Exclude schema → internalResult
    func testExcludeSchemaEmitsInternalResult() {
        let json = #"{"exclude":[]}"#
        let events = parseLine(lastMessage: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .internalResult)
    }

    // 4. Suggestions schema → internalResult
    func testSuggestionsSchemaEmitsInternalResult() {
        let json = #"{"suggestions":["foo","bar"]}"#
        let events = parseLine(lastMessage: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .internalResult)
    }

    // 5. Extra business key in outcome JSON → still a real Stop
    func testOutcomeWithExtraKeyIsRealStop() {
        let json = #"{"outcome":"allow","operation":"feature-rollout"}"#
        let events = parseLine(lastMessage: json)
        XCTAssertTrue(events.contains(where: { $0.eventType == .stop }),
                      "Extra business key must not be treated as internal")
    }

    // 6. Non-JSON text → real Stop
    func testPlainTextIsRealStop() {
        let events = parseLine(lastMessage: "Done! All tests pass.")
        XCTAssertTrue(events.contains(where: { $0.eventType == .stop }))
    }

    // 7. nil lastMessage → real Stop (taskComplete with no message is valid user output)
    func testNilLastMessageIsRealStop() {
        let payload: [String: Any] = ["type": "task_complete", "turn_id": "t1"]
        let record: [String: Any] = ["type": "event_msg", "session_id": "s1", "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else { return }
        let context = CodexSessionContext(sessionId: "s1", cwd: "/tmp", source: "codex-cli", originator: nil, toolNamesByCallId: [:])
        let events = CodexEventMapper.parse(line: line, fileURL: URL(fileURLWithPath: "/tmp/s1.jsonl"), context: context).events
        XCTAssertTrue(events.contains(where: { $0.eventType == .stop }))
    }

    // 8. item_completed → TaskCompleted (unchanged, Activity Feed only)
    func testItemCompletedStillEmitsTaskCompleted() {
        let record: [String: Any] = [
            "type": "event_msg",
            "session_id": "s1",
            "payload": [
                "type": "item_completed",
                "turn_id": "t2",
                "item": ["type": "reasoning", "text": "step 1"],
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else { return }
        let context = CodexSessionContext(sessionId: "s1", cwd: "/tmp", source: "codex-cli", originator: nil, toolNamesByCallId: [:])
        let events = CodexEventMapper.parse(line: line, fileURL: URL(fileURLWithPath: "/tmp/s1.jsonl"), context: context).events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .taskCompleted)
    }
}
