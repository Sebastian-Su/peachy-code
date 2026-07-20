# Codex Hook 升级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 peachy-code 对 Codex CLI 的 permission 处理从"日志轮询 + 终端降级"升级为"真 hooks 双向阻塞通道"，达到与 Claude Code 同级，并修复展开视图对降级 transport 显示无效按钮的 UI bug。

**Architecture:** 复用 Claude Code 已有的 `hook-sender.sh` + `LocalServer` `/hook` 端点 + 阻塞连接回写模型。新增 `CodexHookInstaller`（把同一个 hook 脚本注册到 `~/.codex/hooks.json`）和 `CodexHookTransport`（真回写 + 连接关闭自动 dismiss）。因为 `LocalServer` 由 `ClaudeCodeAdapter` 拥有、所有 `/hook` 连接都在此包装 transport，故"按 source 分发 transport"的逻辑放在 `ClaudeCodeAdapter.start()` 的 `onPermissionRequest` 闭包里。会话级去重防止真 hooks 与轮询合成事件重复。

**Tech Stack:** Swift 5.10 / SwiftUI / Network.framework (NWConnection) / SwiftPM / XCTest。macOS 14+。

## Global Constraints

- 模块名（`@testable import`）：`PeachyPet`。
- hook 脚本路径：`~/.peachypet/hooks/hook-sender.sh`（`NSHomeDirectory() + "/.peachypet/hooks/hook-sender.sh"`）。
- Codex hook 配置文件：`~/.codex/hooks.json`（JSON）。
- Codex hook 事件名：**驼峰**（`PreToolUse` / `PermissionRequest` / `SessionStart` 等），与 Claude Code 一致。已实测 codex-cli 0.144.5 二进制 wire schema 确认。
- PermissionRequest 回写格式：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}` —— 与现有 `PermissionDecision.httpResponse` 完全一致，复用不改。
- hook 命令注册项形如：`{"type":"command","command":"~/.peachypet/hooks/hook-sender.sh","args":["--source","codex-cli"],"timeout":600}`。
- 不使用 `--dangerously-bypass-hook-trust`。首版 `CodexHookTransport` capabilities 仅 `[.permissionResponse]`。
- 所有 print 日志前缀：`[PeachyPet]`。
- Codex source 识别：用 `AgentEvent.assistantClientKind`（`.codexCLI` / `.codexDesktop` / `.codex` 为 Codex；`.claude` 为 CC）。
- 提交信息用中文，格式 `类型: 核心改动`，不加 Co-Authored-By。

---

### Task 0: 修复 rename 遗留的测试 import 断裂

**背景：** 上一次全局改名后，`Tests/` 里的模块导入未同步更新，导致测试 target 无法编译。必须先修，否则后续所有测试步骤都跑不起来。

**Files:**
- Modify: `Tests/*.swift`（所有仍引用旧模块名的文件）

**Interfaces:**
- Consumes: 无
- Produces: 可编译的测试 target（后续任务依赖）

- [ ] **Step 1: 确认受影响文件**

Run: `rg -n "@testable import" Tests/`
Expected: 列出测试文件当前使用的模块导入

- [ ] **Step 2: 批量替换 import**

将受影响文件的模块导入统一改为：

```swift
@testable import PeachyPet
```

- [ ] **Step 3: 验证无残留**

Run: `rg -n "@testable import" Tests/ | rg -v "PeachyPet"`
Expected: 无输出

- [ ] **Step 4: 编译测试 target**

Run: `swift build --build-tests 2>&1 | grep -E "error:|Compiling|Build complete" | tail -10`
Expected: `Build complete!`（无 error）

- [ ] **Step 5: 跑一次现有测试确保基线绿**

Run: `swift test 2>&1 | tail -15`
Expected: 全部通过（`Test Suite ... passed`）

- [ ] **Step 6: Commit**

```bash
git add Tests/
git commit -m "fix: 修复改名遗留的测试模块导入"
```

---

### Task 1: CodexHookInstaller — 注册 hook 到 ~/.codex/hooks.json

**背景：** 仿 `Sources/Services/HookInstaller.swift`（Claude Code 的安装器）。把已有的 `~/.peachypet/hooks/hook-sender.sh` 注册到 Codex 的 `~/.codex/hooks.json`，幂等，只增删自己那条，保留他人 hook（如 AgentPet）。脚本本身复用 `HookInstaller.ensureScriptExists()` 产出的同一份，本任务不重写脚本。

**Files:**
- Create: `Sources/Services/CodexHookInstaller.swift`
- Test: `Tests/CodexHookInstallerTests.swift`

**Interfaces:**
- Consumes: `Constants.serverPort`（已存在）；`HookInstaller.ensureScriptExists()`（已存在，`static func ensureScriptExists() throws`）。
- Produces:
  - `enum CodexHookInstaller`
  - `static func install() throws`
  - `static func uninstall() throws`
  - `static func isRegistered() -> Bool`
  - `static var hookEvents: [String]`（驼峰事件名数组）
  - `static func hooksJSONPath() -> String`（返回 `~/.codex/hooks.json` 绝对路径；测试可通过参数注入自定义路径 — 见下）

- [ ] **Step 1: 写失败测试**

创建 `Tests/CodexHookInstallerTests.swift`：

```swift
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
        let entries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let ourCount = entries.filter { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { ($0["command"] as? String)?.contains("hook-sender.sh") == true }
        }.count
        XCTAssertEqual(ourCount, 1, "duplicate hook entry created")
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CodexHookInstallerTests 2>&1 | tail -10`
Expected: 编译失败 `cannot find 'CodexHookInstaller' in scope`

- [ ] **Step 3: 实现 CodexHookInstaller**

创建 `Sources/Services/CodexHookInstaller.swift`：

```swift
import Foundation

/// Manages peachy-code hook registration in ~/.codex/hooks.json (Codex CLI).
/// Reuses the same hook-sender.sh script installed by HookInstaller.
enum CodexHookInstaller {

    private static let hookCommand = "~/.peachy-code/hooks/hook-sender.sh"

    /// Codex-supported events we subscribe to (camelCase, matches Codex 0.144.5).
    static let hookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
    ]

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

        for event in hookEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entryHasOurHook($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

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

    private static func writeJSON(_ obj: [String: Any], to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter CodexHookInstallerTests 2>&1 | tail -10`
Expected: 4 个测试全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/CodexHookInstaller.swift Tests/CodexHookInstallerTests.swift
git commit -m "feature: 新增 CodexHookInstaller 注册 hook 到 codex hooks.json"
```

---

### Task 2: CodexHookTransport — 真双向回写 + 连接关闭自动 dismiss

**背景：** 仿 `Sources/Adapters/ClaudeCode/HookConnectionTransport.swift`。承载 Codex 真 hooks 的 permission 回写。核心差异：capabilities 仅 `[.permissionResponse]`（首版不支持 updatedInput/textInput/updatedPermissions），且这些方法对 Codex 无操作（no-op，因为 UI 在 capabilities 缺失时不会调用它们，但协议要求实现）。

**Files:**
- Create: `Sources/Adapters/Codex/CodexHookTransport.swift`
- Test: `Tests/CodexHookTransportTests.swift`

**Interfaces:**
- Consumes: `PermissionDecision.httpResponse`（已存在，返回 `(status: String, body: String, exitCode: Int)`）；`ResponseTransport` 协议；`NWConnection`。
- Produces: `final class CodexHookTransport: ResponseTransport`，构造 `init(connection: NWConnection)`。

- [ ] **Step 1: 写失败测试**

创建 `Tests/CodexHookTransportTests.swift`：

```swift
import XCTest
import Network
@testable import peachy_code

final class CodexHookTransportTests: XCTestCase {
    func testCapabilitiesOnlyPermissionResponse() {
        let conn = NWConnection(host: "localhost", port: 1, using: .tcp)
        let transport = CodexHookTransport(connection: conn)
        XCTAssertEqual(transport.capabilities, [.permissionResponse])
        XCTAssertFalse(transport.capabilities.contains(.openTerminal))
        XCTAssertFalse(transport.capabilities.contains(.updatedInput))
        conn.cancel()
    }

    func testDenyHttpResponseFormatMatchesCodexContract() {
        // 验证 deny 的回写格式与 Codex PermissionRequest 契约一致
        let (status, body, exit) = PermissionDecision.deny.httpResponse
        XCTAssertEqual(status, "403 Forbidden")
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(body.contains("\"hookEventName\":\"PermissionRequest\""))
        XCTAssertTrue(body.contains("\"decision\":{\"behavior\":\"deny\"}"))
    }

    func testAllowHttpResponseFormat() {
        let (status, body, exit) = PermissionDecision.allow.httpResponse
        XCTAssertEqual(status, "200 OK")
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(body.contains("\"decision\":{\"behavior\":\"allow\"}"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CodexHookTransportTests 2>&1 | tail -10`
Expected: `cannot find 'CodexHookTransport' in scope`

- [ ] **Step 3: 实现 CodexHookTransport**

创建 `Sources/Adapters/Codex/CodexHookTransport.swift`：

```swift
import Foundation
import Network

/// Wraps an NWConnection held open by the Codex hook script (hook-sender.sh --source codex-cli).
/// Codex PermissionRequest hooks block on curl until we return a decision — same model as
/// HookConnectionTransport. First version supports allow/deny only.
final class CodexHookTransport: ResponseTransport {
    private let connection: NWConnection

    var capabilities: Set<ResponseCapability> {
        [.permissionResponse]
    }

    var isAlive: Bool {
        switch connection.state {
        case .ready, .preparing, .setup:
            return true
        default:
            return false
        }
    }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func sendDecision(_ decision: PermissionDecision) {
        let (status, body, exitHint) = decision.httpResponse
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nX-Exit-Code: \(exitHint)\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // Codex first version does not support these; capabilities excludes them so UI never calls them.
    func sendAllowWithUpdatedInput(_ updatedInput: [String: Any]) {
        sendDecision(.allow)
    }

    func sendAllowWithUpdatedPermissions(_ permissions: [[String: Any]]) {
        sendDecision(.allow)
    }

    func cancel() {
        connection.cancel()
    }

    func onRemoteClose(_ handler: @escaping () -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                DispatchQueue.main.async { handler() }
            default:
                break
            }
        }
        monitorReceive(handler)
    }

    // MARK: - Private

    private func monitorReceive(_ handler: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                DispatchQueue.main.async { handler() }
            } else {
                self?.monitorReceive(handler)
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter CodexHookTransportTests 2>&1 | tail -10`
Expected: 3 个测试全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Adapters/Codex/CodexHookTransport.swift Tests/CodexHookTransportTests.swift
git commit -m "feature: 新增 CodexHookTransport 支持 Codex permission 真回写"
```

---

### Task 3: 按 source 分发 transport + 安装 Codex hook

**背景：** `LocalServer` 归 `ClaudeCodeAdapter` 所有，所有 `/hook` 连接（含 Codex 的）都在 `ClaudeCodeAdapter.start()` 的 `localServer.onPermissionRequest` 闭包里被包成 `HookConnectionTransport`（`ClaudeCodeAdapter.swift:49-52`）。改为按 `event.assistantClientKind` 选择 transport：Codex 用 `CodexHookTransport`，其余用 `HookConnectionTransport`。同时把 Codex hook 安装接到 `CodexAdapter.install()`。

**Files:**
- Modify: `Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift:49-52`
- Modify: `Sources/Adapters/Codex/CodexAdapter.swift`（`install()` / `isRegistered()`）
- Test: `Tests/CodexAdapterInstallTests.swift`

**Interfaces:**
- Consumes: `CodexHookTransport(connection:)`（Task 2）；`HookConnectionTransport(connection:)`（已存在）；`AgentEvent.assistantClientKind`（已存在）；`CodexHookInstaller.install()/uninstall()/isRegistered()`（Task 1）；`AgentEvent(hookEventName:...source:...)` 构造器（已存在）。
- Produces: `CodexAdapter.install()` 现在真正注册 hook；`CodexAdapter.isRegistered()` 反映 hooks.json 状态。

- [ ] **Step 1: 写失败测试（Codex adapter 安装委托）**

创建 `Tests/CodexAdapterInstallTests.swift`：

```swift
import XCTest
@testable import peachy_code

final class CodexAdapterInstallTests: XCTestCase {
    // assistantClientKind 是分发依据 — 固化其对 codex-cli / claude 的判定
    func testAssistantClientKindClassifiesCodexCLI() {
        let e = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1",
                           cwd: nil, source: "codex-cli")
        XCTAssertEqual(e.assistantClientKind, .codexCLI)
    }

    func testAssistantClientKindClassifiesClaude() {
        let e = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1",
                           cwd: nil, source: "startup")
        XCTAssertEqual(e.assistantClientKind, .claude)
    }

    func testCodexEventIsRoutedToCodexTransportKind() {
        // 分发判据：非 .claude 即用 CodexHookTransport
        let codex = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s", cwd: nil, source: "codex-cli")
        let claude = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s", cwd: nil, source: "startup")
        XCTAssertTrue(codex.assistantClientKind != .claude)
        XCTAssertTrue(claude.assistantClientKind == .claude)
    }
}
```

注：`AgentEvent` 的 init 需支持这些命名参数。若现有 init 不便直接构造，先 Run `grep -n "init(" Sources/Models/AgentEvent.swift` 确认可用的便利构造器；测试里用现有构造器的实际签名。

- [ ] **Step 2: 跑测试确认失败/基线**

Run: `swift test --filter CodexAdapterInstallTests 2>&1 | tail -10`
Expected: 编译通过则测试 PASS（这些断言验证的是已有 `assistantClientKind`）。若 init 签名不符导致编译失败，按实际签名修正测试后再跑，直到 PASS。

- [ ] **Step 3: 改 ClaudeCodeAdapter 按 source 分发 transport**

修改 `Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift`，将 `start()` 里的 `localServer.onPermissionRequest` 闭包（当前 49-52 行）替换为：

```swift
        localServer.onPermissionRequest = { [weak self] event, connection in
            let transport: ResponseTransport
            if event.assistantClientKind == .claude {
                transport = HookConnectionTransport(connection: connection)
            } else {
                // Codex (and other non-Claude) hooks POST to the same /hook endpoint.
                transport = CodexHookTransport(connection: connection)
            }
            self?.onPermissionRequest?(event, transport)
        }
```

- [ ] **Step 4: 改 CodexAdapter.install/isRegistered 接入 hook 安装**

修改 `Sources/Adapters/Codex/CodexAdapter.swift`，将现有的：

```swift
    func isRegistered() -> Bool {
        true
    }

    func install() throws {
        // Codex log ingestion requires no hook/plugin install.
    }

    func uninstall() {
        // Nothing to uninstall for log ingestion.
    }
```

替换为：

```swift
    func isRegistered() -> Bool {
        CodexHookInstaller.isRegistered()
    }

    func install() throws {
        try CodexHookInstaller.install()
    }

    func uninstall() {
        try? CodexHookInstaller.uninstall()
    }
```

- [ ] **Step 5: 编译 + 跑测试**

Run: `swift build 2>&1 | grep -E "error:|Build complete" | tail -5`
Expected: `Build complete!`

Run: `swift test --filter CodexAdapterInstallTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift Sources/Adapters/Codex/CodexAdapter.swift Tests/CodexAdapterInstallTests.swift
git commit -m "feature: 按 source 分发 permission transport 并接入 Codex hook 安装"
```

---

### Task 4: 会话级去重 — hooks 送达的会话静默轮询合成

**背景：** hooks（新）与日志轮询（旧）同时开启。真 hooks 送达的会话里，轮询会重复合成 permission 与普通事件，导致重复气泡/活动流。方案：在 `CodexAdapter` 维护 `sessionsWithLiveHooks: Set<String>`。判定"来自真 hook"的信号是 `event.source` 为 codex 且**该事件来自 LocalServer**（hook 推送），而 `CodexSessionMonitor` 产生的事件来自日志轮询。由于两条路都产生 `AgentEvent`，需要一个明确标记区分来源。

采用最小侵入方案：`CodexAdapter` 只处理来自 `CodexSessionMonitor`（轮询）的事件；真 hook 事件根本不经过 `CodexAdapter`（它们经 LocalServer→ClaudeCodeAdapter）。因此"某会话是否已有真 hooks"这个状态必须**跨 adapter 共享**。引入一个轻量单例 `CodexHookLiveness`（`@MainActor`），LocalServer 路径标记会话有 live hook，`CodexAdapter.route` 查询它决定是否静默轮询事件。

**Files:**
- Create: `Sources/Adapters/Codex/CodexHookLiveness.swift`
- Modify: `Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift`（`start()` 的 `onEventReceived` 与 `onPermissionRequest`：对 codex source 事件标记会话）
- Modify: `Sources/Adapters/Codex/CodexAdapter.swift`（`route` 前查询 liveness）
- Test: `Tests/CodexHookLivenessTests.swift`

**Interfaces:**
- Consumes: `AgentEvent.assistantClientKind`、`AgentEvent.sessionId`。
- Produces:
  - `@MainActor final class CodexHookLiveness`
  - `static let shared: CodexHookLiveness`
  - `func markLive(sessionId: String)`
  - `func isLive(sessionId: String?) -> Bool`
  - `func clear(sessionId: String)`

- [ ] **Step 1: 写失败测试**

创建 `Tests/CodexHookLivenessTests.swift`：

```swift
import XCTest
@testable import peachy_code

@MainActor
final class CodexHookLivenessTests: XCTestCase {
    func testMarkAndQuery() {
        let liveness = CodexHookLiveness()
        XCTAssertFalse(liveness.isLive(sessionId: "s1"))
        liveness.markLive(sessionId: "s1")
        XCTAssertTrue(liveness.isLive(sessionId: "s1"))
    }

    func testNilSessionIsNeverLive() {
        let liveness = CodexHookLiveness()
        liveness.markLive(sessionId: "s1")
        XCTAssertFalse(liveness.isLive(sessionId: nil))
    }

    func testClearRemovesLiveness() {
        let liveness = CodexHookLiveness()
        liveness.markLive(sessionId: "s1")
        liveness.clear(sessionId: "s1")
        XCTAssertFalse(liveness.isLive(sessionId: "s1"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CodexHookLivenessTests 2>&1 | tail -10`
Expected: `cannot find 'CodexHookLiveness' in scope`

- [ ] **Step 3: 实现 CodexHookLiveness**

创建 `Sources/Adapters/Codex/CodexHookLiveness.swift`：

```swift
import Foundation

/// Tracks which Codex sessions have delivered real hook events.
/// When a session has live hooks, the log-polling fallback (CodexSessionMonitor)
/// must stay silent for that session to avoid duplicate bubbles / feed entries.
@MainActor
final class CodexHookLiveness {
    static let shared = CodexHookLiveness()

    private var liveSessions: Set<String> = []

    func markLive(sessionId: String) {
        liveSessions.insert(sessionId)
    }

    func isLive(sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return liveSessions.contains(sessionId)
    }

    func clear(sessionId: String) {
        liveSessions.remove(sessionId)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter CodexHookLivenessTests 2>&1 | tail -10`
Expected: 3 个 PASS

- [ ] **Step 5: 在 LocalServer 路径标记会话有 live hook**

修改 `Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift` 的 `start()`。在 `onEventReceived` 与 `onPermissionRequest` 两个闭包里，对 codex source 事件标记会话（放在把事件/transport 往上抛之前）。

`onEventReceived` 改为：

```swift
        localServer.onEventReceived = { [weak self] event in
            if event.assistantClientKind != .claude, let sid = event.sessionId {
                Task { @MainActor in CodexHookLiveness.shared.markLive(sessionId: sid) }
            }
            self?.onEvent?(event)
        }
```

`onPermissionRequest` 闭包（Task 3 已改过的那段）在分发前加同样标记：

```swift
        localServer.onPermissionRequest = { [weak self] event, connection in
            if event.assistantClientKind != .claude, let sid = event.sessionId {
                Task { @MainActor in CodexHookLiveness.shared.markLive(sessionId: sid) }
            }
            let transport: ResponseTransport
            if event.assistantClientKind == .claude {
                transport = HookConnectionTransport(connection: connection)
            } else {
                transport = CodexHookTransport(connection: connection)
            }
            self?.onPermissionRequest?(event, transport)
        }
```

- [ ] **Step 6: 在 CodexAdapter.route 查询 liveness 静默轮询事件**

修改 `Sources/Adapters/Codex/CodexAdapter.swift` 的 `route(_:)`。`CodexSessionMonitor` 回调在后台线程，`CodexHookLiveness` 是 `@MainActor`，故查询需切主线程。把 `monitor.onEventReceived` 与 `route` 调整为：

在 `start()` 中：

```swift
    func start() throws {
        monitor.onEventReceived = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                // 该会话已有真 hooks → 轮询事件全部静默，避免重复
                if CodexHookLiveness.shared.isLive(sessionId: event.sessionId) { return }
                self.route(event)
            }
        }
        monitor.start()
    }
```

（`route(_:)` 本身保持不变。）

- [ ] **Step 7: 编译 + 全量测试**

Run: `swift build 2>&1 | grep -E "error:|Build complete" | tail -5`
Expected: `Build complete!`

Run: `swift test 2>&1 | tail -15`
Expected: 全部 PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/Adapters/Codex/CodexHookLiveness.swift Sources/Adapters/ClaudeCode/ClaudeCodeAdapter.swift Sources/Adapters/Codex/CodexAdapter.swift Tests/CodexHookLivenessTests.swift
git commit -m "feature: 会话级去重 hooks 送达后静默 Codex 轮询合成"
```

**关于 toolUseId 兜底（spec 单元 4）：** `PendingPermissionStore.isDuplicate`（`PendingPermissionStore.swift:417-441`）已按 `sessionId + toolUseId`（及 toolInput 签名）对进入 store 的 permission 去重。真 hook 首次送达前 ≤1 秒窗口内轮询已合成的气泡，与随后真 hook 的 permission 若 `toolUseId` 相同，会被这层已有逻辑丢弃先到/后到之一。会话级去重（本任务）+ 这层 toolUseId 去重叠加，共同满足 spec 的兜底要求，**无需新增去重代码**。

---

### Task 5: hook trust 用户提示（Onboarding / 设置页）

**背景：** spec 要求——安装 Codex hook 后，用户需在 Codex TUI 手动选择 "Trust" 才生效；在此之前走轮询降级。App 需明确提示用户这一步，避免"装了没反应"的困惑。找到现有触发 Codex hook 安装的 UI 位置，在其附近加一句提示文案。

**Files:**
- Modify: 现有触发 Codex 安装/显示 Codex 状态的视图（先定位，见 Step 1）
- 无新增测试（纯文案 UI）

**Interfaces:**
- Consumes: `CodexAdapter.isRegistered()`（Task 3 后反映真实状态）。
- Produces: 无。

- [ ] **Step 1: 定位 Codex 安装/状态的 UI 位置**

Run: `grep -rnE "codexAdapter|Codex.*install|isRegistered|Onboarding.*[Cc]odex|codex" Sources/Views/ --include="*.swift" | grep -iE "install|register|onboard|enable|status"`
Expected: 找到设置页或 Onboarding 中处理 Codex 启用/状态的视图与行号。

- [ ] **Step 2: 在该位置加 trust 提示文案**

在定位到的 Codex 状态/启用区域附近，加一段说明文本（按该视图现有的 Text 样式，参照周围代码的字号/颜色常量）：

```swift
Text("已为 Codex 安装 hook。请在下次打开 Codex 时选择「Trust」以启用实时 permission；在此之前 Codex 会以终端模式工作。")
    .font(.system(size: 11))
    .foregroundColor(Constants.textMuted)
```

（具体嵌入方式跟随该视图的布局；文案可按现有 UI 语言风格微调，中英不限，保持与周围一致。）

- [ ] **Step 3: 编译验证**

Run: `swift build 2>&1 | grep -E "error:|Build complete" | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Views/
git commit -m "feature: 设置页提示用户在 Codex 中信任 hook"
```

---

### Task 6: 修复 ExpandedPermissionView 对降级 transport 显示无效按钮

**背景：** `PermissionContentView` 已有 `supportsOverlayResponses` / `isOpenTerminalFallback` 判断（`:33-41`），据此对仅 `.openTerminal` 的 transport 显示 "Open Terminal"。但 `ExpandedPermissionView`（展开视图 ⌘P）的 `body`（`:62-99`）没有这个分支，standard 路径一律渲染 Allow/Deny，对 Codex 降级路径（`TerminalFallbackTransport`）无效且误导。修复：加同样的 capabilities 判断（按 capabilities 而非 source —— 升级后 `CodexHookTransport` 有 `.permissionResponse`，会正确显示 Allow/Deny）。

**Files:**
- Modify: `Sources/Views/Overlay/ExpandedPermissionView.swift`（加计算属性 + body 分支 + fallback 动作视图）

**Interfaces:**
- Consumes: `permission.transport.capabilities`（`Set<ResponseCapability>`，已存在）；视图已有的 `focusTerminal(...)`（header 里已在用，见 `:128-135`）。
- Produces: 无（纯 UI）。

- [ ] **Step 1: 加 capabilities 计算属性**

在 `ExpandedPermissionView` 里（`planOptions` 定义附近，`:55` 之后），加：

```swift
    private var supportsOverlayResponses: Bool {
        let caps = permission.transport.capabilities
        return caps.contains(.permissionResponse)
            || caps.contains(.updatedInput)
            || caps.contains(.updatedPermissions)
    }
    private var isOpenTerminalFallback: Bool {
        !supportsOverlayResponses && permission.transport.capabilities.contains(.openTerminal)
    }
```

- [ ] **Step 2: body 内容区加 fallback 分支**

把 `body` 里的内容 ScrollView 分支（`:70-76`）改为优先判断 fallback：

```swift
                if isOpenTerminalFallback {
                    terminalFallbackContent
                } else if isPlan {
                    planContent
                } else if isQuestion {
                    questionContent
                } else {
                    standardContent
                }
```

- [ ] **Step 3: body 动作区加 fallback 分支**

把动作栏分支（`:84-90`）改为：

```swift
                if isOpenTerminalFallback {
                    terminalFallbackActions
                } else if isPlan {
                    planActions
                } else if isQuestion {
                    questionActions
                } else {
                    standardActions
                }
```

- [ ] **Step 4: 实现 fallback 内容与动作视图**

在 `ExpandedPermissionView` 里新增两个视图（放在 `standardContent` / `standardActions` 定义附近）：

```swift
    private var terminalFallbackContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(permission.event.message ?? "This agent requires a response in the terminal.")
                .font(Constants.body(size: 14))
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255))
            Text("This agent can't accept a decision from here. Open the terminal to respond.")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private var terminalFallbackActions: some View {
        Button {
            focusTerminal(
                pid: permission.event.terminalPid,
                shellPid: permission.event.shellPid,
                projectDir: permission.event.cwd,
                sessionId: permission.event.sessionId,
                sessions: sessionStore.sessions
            )
        } label: {
            Text("Open Terminal")
                .font(Constants.heading(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(red: 249/255, green: 93/255, blue: 2/255), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
```

注：若 `focusTerminal` 的签名与 header 用法（`:128-135`）不同，Run `grep -n "func focusTerminal" Sources/Views/Overlay/*.swift Sources/Utilities/*.swift` 确认实际签名并对齐调用。

- [ ] **Step 5: 编译验证**

Run: `swift build 2>&1 | grep -E "error:|Build complete" | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: 手动确认（构建产物）**

Run: `swift build 2>&1 | tail -1`
Expected: `Build complete!`（UI 行为在 Task 7 真机验收里覆盖）

- [ ] **Step 7: Commit**

```bash
git add Sources/Views/Overlay/ExpandedPermissionView.swift
git commit -m "fix: 展开视图对降级 transport 显示 Open Terminal 而非无效按钮"
```

---

### Task 7: 真机端到端联调与验收

**背景：** 单元/集成测试无法覆盖"Codex 真实触发 permission → hook trust → 回写生效 → TUI 抢答同步"的完整链路。本任务是手动验收，产出验收记录（不入库的本地调试记录）。

**Files:**
- 无代码改动（纯验证）。如发现 bug，回到对应 Task 修复。

**Interfaces:**
- Consumes: 全部前序任务的产物。
- Produces: 验收结论。

- [ ] **Step 1: 构建并运行 App**

Run: `swift build 2>&1 | tail -1 && swift run &`
Expected: App 启动，菜单栏出现 mascot。

- [ ] **Step 2: 安装 Codex hook 并确认 hooks.json**

在 App 里触发 Codex hook 安装（Onboarding / 设置页），然后：
Run: `python3 -c "import json; d=json.load(open('$HOME/.codex/hooks.json')); print(list(d['hooks'].keys()))"`
Expected: 包含 `PermissionRequest`、`PreToolUse` 等 10 个事件，且 command 指向 `hook-sender.sh --source codex-cli`。

- [ ] **Step 3: 在 Codex TUI 授权 hook trust**

启动 codex，在 "Hooks need review" 提示里选 "Trust all and continue"。
Expected: hook 被信任，后续事件会实时推送。

- [ ] **Step 4: 触发真实 permission 并验证回写**

在 codex 里执行一个需要审批的操作（如危险命令）。
Expected:
- mascot 弹 permission 气泡（实时，非 1 秒延迟）。
- 点 Allow → Codex 真正执行；点 Deny → Codex 拒绝。
- 展开视图（⌘P）显示可用的 Allow/Deny（因 `CodexHookTransport` 有 `.permissionResponse`）。

- [ ] **Step 5: 验证 TUI 抢答自动同步**

再触发一次 permission，这次**在 Codex 终端里直接回答**（不点 mascot）。
Expected: mascot 气泡自动消失、状态回落（`onRemoteClose` 生效）。

- [ ] **Step 6: 验证未授权时降级不中断**

新开一个未授权 trust 的 codex 会话，触发 permission。
Expected: 走轮询降级，气泡显示 "Open Terminal"，无重复气泡（会话级去重生效）。

- [ ] **Step 7: 记录验收结论**

把 Step 1-6 的实际结果记录为本地调试记录（不入库）。若全绿，升级完成；若某步失败，回对应 Task 修复后重跑本任务。

---

## 验收标准（对应 spec）

1. Codex 已授权 hook trust 时，permission 走真双向通道：allow/deny 真正生效、实时、可回写。（Task 7 Step 4）
2. TUI 抢答后 peachy 气泡自动消失、状态同步。（Task 7 Step 5）
3. 未授权 / 旧版本时自动降级到轮询 + 终端，体验不中断，无重复气泡。（Task 7 Step 6）
4. 展开视图按 capabilities 正确显示按钮。（Task 6 + Task 7 Step 4）
5. `swift build` 通过；单元与集成测试通过。（各 Task 的编译/测试步骤）
