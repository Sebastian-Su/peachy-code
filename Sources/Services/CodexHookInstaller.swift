import Foundation

/// Manages PeachyPet hook registration in ~/.codex/hooks.json (Codex CLI).
/// Reuses the same hook-sender.sh script installed by HookInstaller.
enum CodexHookInstaller {

    private static let hookCommand = "~/.peachypet/hooks/hook-sender.sh"

    /// Codex-supported events we subscribe to (camelCase, matches Codex 0.144.5).
    static let hookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
    ]

    /// Older PeachyPet versions intercepted Codex approvals here. That overrides Codex's
    /// configured reviewer, including the built-in auto-reviewer, so installs migrate
    /// this hook away while preserving hooks owned by other applications.
    private static let deprecatedHookEvents = ["PermissionRequest"]

    static func hooksJSONPath() -> String {
        NSHomeDirectory() + "/.codex/hooks.json"
    }

    static func isRegistered() -> Bool {
        isRegistered(hooksJSONPath: hooksJSONPath())
    }

    static func isRegistered(hooksJSONPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for event in hookEvents {
            if let entries = hooks[event] as? [[String: Any]],
               entries.contains(where: { entryHasOurHook($0) }) {
                return true
            }
        }
        return false
    }

    /// Register hooks. `ensureScript` defaults true (writes the shared script);
    /// tests pass false to skip touching the real home dir.
    static func install(hooksJSONPath path: String = hooksJSONPath(), ensureScript: Bool = true) throws {
        if ensureScript {
            try HookInstaller.ensureScriptExists()
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        removeOurHooks(from: &hooks, for: deprecatedHookEvents)
        let entry: [String: Any] = [
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": hookCommand,
                "args": ["--source", "codex-cli"],
                "timeout": 600,
            ]],
        ]

        for event in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let already = entries.contains { entryHasOurHook($0) }
            if !already { entries.append(entry) }
            hooks[event] = entries
        }

        root["hooks"] = hooks
        try writeJSON(root, to: path)
    }

    static func uninstall(hooksJSONPath path: String = hooksJSONPath()) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        removeOurHooks(from: &hooks, for: hookEvents + deprecatedHookEvents)

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeJSON(root, to: path)
    }

    // MARK: - Private

    private static func entryHasOurHook(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains("hook-sender.sh") == true }
    }

    private static func removeOurHooks(from hooks: inout [String: Any], for events: [String]) {
        for event in events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entryHasOurHook($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
    }

    private static func writeJSON(_ obj: [String: Any], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
