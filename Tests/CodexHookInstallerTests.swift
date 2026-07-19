import XCTest
@testable import peachy_code

final class CodexHookInstallerTests: XCTestCase {
    private var tmpDir: URL!
    private var hooksPath: String!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-hook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        hooksPath = tmpDir.appendingPathComponent("hooks.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testInstallCreatesAllEventsPointingToScript() throws {
        try CodexHookInstaller.install(hooksJSONPath: hooksPath, ensureScript: false)

        let data = try Data(contentsOf: URL(fileURLWithPath: hooksPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])

        for event in CodexHookInstaller.hookEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let hasOurs = entries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains("hook-sender.sh") == true }
            }
            XCTAssertTrue(hasOurs, "event \(event) missing our hook")
        }
    }

    func testInstallIsIdempotent() throws {
        try CodexHookInstaller.install(hooksJSONPath: hooksPath, ensureScript: false)
        try CodexHookInstaller.install(hooksJSONPath: hooksPath, ensureScript: false)

        let data = try Data(contentsOf: URL(fileURLWithPath: hooksPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        // 逐一核对全部事件，防止幂等 bug 只出现在部分事件时漏检
        for event in CodexHookInstaller.hookEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing event \(event)")
            let ourCount = entries.filter { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains("hook-sender.sh") == true }
            }.count
            XCTAssertEqual(ourCount, 1, "duplicate hook entry for event \(event)")
        }
    }

    func testInstallPreservesForeignHooks() throws {
        let foreign: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": "/Applications/AgentPet.app/foo"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: foreign)
        try data.write(to: URL(fileURLWithPath: hooksPath))

        try CodexHookInstaller.install(hooksJSONPath: hooksPath, ensureScript: false)

        let outData = try Data(contentsOf: URL(fileURLWithPath: hooksPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: outData) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let hasForeign = pre.contains { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String)?.contains("AgentPet") == true }
        }
        XCTAssertTrue(hasForeign, "foreign AgentPet hook was removed")
    }

    func testUninstallRemovesOnlyOurs() throws {
        let foreign: [String: Any] = [
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "/Applications/AgentPet.app/foo"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: foreign).write(to: URL(fileURLWithPath: hooksPath))
        try CodexHookInstaller.install(hooksJSONPath: hooksPath, ensureScript: false)

        try CodexHookInstaller.uninstall(hooksJSONPath: hooksPath)

        let outData = try Data(contentsOf: URL(fileURLWithPath: hooksPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: outData) as? [String: Any])
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]
        // 我们的 hook 全没了
        for event in CodexHookInstaller.hookEvents {
            if let entries = hooks[event] as? [[String: Any]] {
                let hasOurs = entries.contains { entry in
                    guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                    return inner.contains { ($0["command"] as? String)?.contains("hook-sender.sh") == true }
                }
                XCTAssertFalse(hasOurs, "our hook survived uninstall in \(event)")
            }
        }
        // AgentPet 还在
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertTrue(pre.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("AgentPet") == true } == true
        })
    }
}
