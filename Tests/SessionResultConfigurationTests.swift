import XCTest
@testable import PeachyPet

final class SessionResultConfigurationTests: XCTestCase {
    @MainActor
    func testLegacySettingsMigrateOnceAndAgentEditsStayIndependent() throws {
        let suite = "PeachyPetResultConfig-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sessionResult.enabled")
        defaults.set("executable", forKey: "sessionResult.backend")
        defaults.set("/tmp/sample-tool", forKey: "sessionResult.executablePath")
        defaults.set("Keep the headings", forKey: "sessionResult.instructions")
        defaults.set("reuse", forKey: "sessionResult.conversation")
        defaults.set("agent", forKey: "sessionResult.destination")

        let plugin = SessionResultPlugin(defaults: defaults)
        let original = try XCTUnwrap(plugin.configuration(for: .claudeCode))
        XCTAssertEqual(plugin.configuration(for: .codex), original)
        XCTAssertEqual(plugin.configuration(for: .copilot), original)
        XCTAssertTrue(original.isEnabled)
        XCTAssertEqual(original.instructions, "Keep the headings")
        XCTAssertEqual(original.executablePath, "/tmp/sample-tool")
        XCTAssertEqual(original.conversation, .reuse)
        XCTAssertEqual(original.destination, .agent)
        XCTAssertTrue(original.triggerKeyword.isEmpty)

        var draft = original
        draft.instructions = "New Codex instructions"
        draft.triggerKeyword = "Release"
        XCTAssertEqual(plugin.configuration(for: .codex), original)
        XCTAssertEqual(SessionResultPlugin(defaults: defaults).configuration(for: .codex), original)

        plugin.save(draft, for: .codex)
        let reopened = SessionResultPlugin(defaults: defaults)
        XCTAssertEqual(reopened.configuration(for: .codex), draft)
        XCTAssertEqual(reopened.configuration(for: .claudeCode), original)
        XCTAssertEqual(reopened.configuration(for: .copilot), original)
        XCTAssertEqual(defaults.string(forKey: "sessionResult.instructions"), original.instructions)
    }

    @MainActor
    func testEachAgentUsesOnlyItsSavedPromptAndKeywordBeforeLaunchingTool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PeachyPetResultConfig-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let plugin = SessionResultPlugin(defaults: defaults)
        let tool = directory.appendingPathComponent("tool")
        let captured = directory.appendingPathComponent("input")
        try """
        #!/bin/bash
        cat > "\(captured.path)"
        printf 'Report'
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)

        let reply = AgentEvent(hookEventName: "Stop", sessionId: "same-id",
                               lastAssistantMessage: "release ready", client: "codex-cli")
        XCTAssertNil(plugin.receive(reply))
        var codex = SessionResultPlugin.Configuration(
            backend: .executable, executablePath: tool.path, instructions: "Codex prompt",
            destination: .agent, triggerKeyword: " RELEASE "
        )
        plugin.save(codex, for: .codex)
        var claude = codex
        claude.instructions = "Claude prompt"
        claude.triggerKeyword = "deployment"
        plugin.save(claude, for: .claudeCode)
        codex.instructions = "Unsaved edit"

        let ignored = AgentEvent(hookEventName: "Stop", sessionId: "same-id",
                                 lastAssistantMessage: "release ready")
        let ignoredOutput = await plugin.receive(ignored)?.value
        XCTAssertNil(ignoredOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.path))

        let codexOutput = await plugin.receive(reply)?.value
        XCTAssertNotNil(codexOutput)
        var input = try String(contentsOf: captured, encoding: .utf8)
        XCTAssertTrue(input.contains("Codex prompt"))
        XCTAssertFalse(input.contains("Unsaved edit"))
        XCTAssertFalse(input.contains("Claude prompt"))

        let claudeReply = AgentEvent(hookEventName: "Stop", sessionId: "same-id",
                                     lastAssistantMessage: "deployment ready")
        let claudeOutput = await plugin.receive(claudeReply)?.value
        XCTAssertNotNil(claudeOutput)
        input = try String(contentsOf: captured, encoding: .utf8)
        XCTAssertTrue(input.contains("Claude prompt"))
        XCTAssertFalse(input.contains("Codex prompt"))
    }
}
