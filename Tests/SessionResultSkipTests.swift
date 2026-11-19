import XCTest
@testable import PeachyPet

final class SessionResultSkipTests: XCTestCase {
    func testChineseProseIgnoresCodePathsAndLinks() {
        XCTAssertTrue(SessionResultPlugin.isChineseReply("""
        已完成迁移，`swift test --filter PaseoRemoteBridgeTests` 全部通过。
        改动在 /tmp/peachypet-paseo-remote/Sources/Services/PaseoRemoteBridge.swift，详见 https://example.com/very/long/english/path。
        ```swift
        let somethingVeryLongInEnglish = PaseoRemoteBridge.event(for: turn)
        ```
        """))
        XCTAssertFalse(SessionResultPlugin.isChineseReply("All checks passed. The release build is ready for review."))
        // Mostly English prose with a few Chinese words is still English.
        XCTAssertFalse(SessionResultPlugin.isChineseReply("The installer for 纳米 Work finished and every regression test passed on both machines."))
        // A four-backtick fence may contain a three-backtick one.
        XCTAssertTrue(SessionResultPlugin.isChineseReply("坐标换算原文：\n````text\nx_px = transform.x * width / 2, kept as the original English note.\n```\nnested\n```\n````"))
        // Nothing but code: there is no prose to translate.
        XCTAssertTrue(SessionResultPlugin.isChineseReply("```\nmake build\n```"))
    }

    func testSkipMarkerToleratesFormatting() {
        for output in ["PEACHYPET_SKIP", " `PEACHYPET_SKIP`\n", "**PEACHYPET_SKIP**。", "peachypet_skip"] {
            XCTAssertTrue(SessionResultPlugin.isSkipMarker(output), output)
        }
        XCTAssertFalse(SessionResultPlugin.isSkipMarker("任务完成"))
        XCTAssertFalse(SessionResultPlugin.isSkipMarker("这份报告提到了 PEACHYPET_SKIP 标记的用法，以及另外三处需要修改的地方，请逐一核对。"))
    }

    func testConfigurationSavedBeforeTheOptionStillDecodes() throws {
        let saved = Data(#"{"isEnabled":true,"backend":"codex","executablePath":"","instructions":"翻译","conversation":"new","destination":"panel","triggerKeyword":""}"#.utf8)
        let configuration = try JSONDecoder().decode(SessionResultPlugin.Configuration.self, from: saved)
        XCTAssertEqual(configuration.instructions, "翻译")
        XCTAssertFalse(configuration.skipsChineseReplies)
    }

    @MainActor
    func testChineseReplyAndSkipMarkerShowNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PeachyPetResultSkip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let launches = directory.appendingPathComponent("launches")
        let tool = directory.appendingPathComponent("tool")
        try """
        #!/bin/bash
        echo run >> "\(launches.path)"
        cat > /dev/null
        printf 'PEACHYPET_SKIP'
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)

        let plugin = SessionResultPlugin(defaults: defaults)
        plugin.save(.init(backend: .executable, executablePath: tool.path, destination: .agent,
                          skipsChineseReplies: true), for: .codex)
        var delivered = 0
        plugin.onResult = { _, _ in delivered += 1 }

        let chinese = AgentEvent(hookEventName: "Stop", sessionId: "s1",
                                 lastAssistantMessage: "全部检查通过，安装包已经准备好。", client: "codex-cli")
        let chineseOutput = await plugin.receive(chinese)?.value
        XCTAssertNil(chineseOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launches.path), "a Chinese reply must not launch the tool")

        let english = AgentEvent(hookEventName: "Stop", sessionId: "s1",
                                 lastAssistantMessage: "All checks passed.", client: "codex-cli")
        let englishOutput = await plugin.receive(english)?.value
        XCTAssertNil(englishOutput, "the skip marker must not continue the source session")
        XCTAssertTrue(FileManager.default.fileExists(atPath: launches.path))
        XCTAssertEqual(delivered, 0)
        XCTAssertNil(plugin.lastErrors[.codex])
    }
}
