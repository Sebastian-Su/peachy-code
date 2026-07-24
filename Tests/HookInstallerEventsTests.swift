import XCTest
@testable import PeachyPet

final class HookInstallerEventsTests: XCTestCase {
    func testSubagentLifecycleHooksAreRegisteredAsPair() {
        XCTAssertTrue(HookInstaller.hookEvents.contains("SubagentStart"))
        XCTAssertTrue(HookInstaller.hookEvents.contains("SubagentStop"))
    }

    func testInstallRemovesLegacyMaskoHooksAndPreservesForeignHooks() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-hook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let settingsPath = tmpDir.appendingPathComponent("settings.json").path
        let existing: [String: Any] = [
            "hooks": [
                "ConfigChange": [
                    ["hooks": [["type": "command", "command": "~/.peachypet/hooks/hook-sender.sh"]]],
                ],
                "PreToolUse": [
                    ["hooks": [
                        ["type": "command", "command": "/Users/test/.masko-desktop/hooks/hook-sender"],
                        ["type": "command", "command": "\"/Applications/AgentPet.app/Contents/MacOS/agentpet\" hook --agent claude"],
                        ["type": "command", "command": "/Applications/OtherPet.app/hook"],
                    ]],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: URL(fileURLWithPath: settingsPath))

        try HookInstaller.install(settingsPath: settingsPath, ensureScript: false)

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let commands = entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        }

        XCTAssertFalse(commands.contains { $0.contains(".masko-desktop") })
        XCTAssertFalse(commands.contains { $0.contains("AgentPet.app") })
        XCTAssertNil(hooks["ConfigChange"])
        XCTAssertTrue(commands.contains("/Applications/OtherPet.app/hook"))
        XCTAssertTrue(commands.contains("~/.peachypet/hooks/hook-sender.sh"))
    }
}
