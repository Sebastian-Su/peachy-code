# Subagent 状态短横线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在会话切换器中用最多 5 条橙色短横线实时展示每个 session 当前运行的 subagent 数量，并在 session idle/end 时清除残留状态。

**Architecture:** Claude Code 和 Codex 都恢复成对的 `SubagentStart`/`SubagentStop` hook；`SessionStore` 以 `sessionId → Set<agentId>` 精确追踪具名 subagent，并以 `sessionId → Int` 降级追踪缺少 `agentId` 的事件，二者之和写入 `AgentSession.activeSubagentCount` 驱动 SwiftUI。所有进入 idle/ended 的路径统一清空两类内存状态和展示计数，`SessionSwitcherStore.refresh` 负责把实时状态刷新到已打开的切换器值类型快照中。

**Tech Stack:** Swift 5.10、SwiftUI、Observation (`@Observable`)、XCTest、macOS 14+、Swift Package Manager

## Global Constraints

- 每个 session 最多显示 5 条橙色短横线，不显示 `+N` 文本。
- 每条短横线为 10 × 2.5 pt、圆角 1.25 pt、间距 4 pt，颜色使用 `Constants.orangePrimary`。
- `activeSubagentCount == 0` 时不渲染指示器容器，不改变普通 session 行高度。
- `SubagentStop` 不触发 `Task Completed` 通知；本计划不调整完成通知语义。
- 不把 subagent 建成独立 session，不展示名称、类型或耗时。
- `activeSubagentIds` 保持内存态，不新增持久化格式。
- 修改 Hook 注册策略后同步更新 `CLAUDE.md`。
- 所有提交使用中文 message，不添加模型署名，不 push。
- 当前工作树已有未提交的 `Sources/Utilities/IDETerminalFocus.swift` 修改；每次只按本计划列出的文件精确 `git add`，绝不能把它混入本功能提交。

---

## File Map

- `Sources/Services/HookInstaller.swift`：Claude Code hook 列表恢复 `SubagentStart`。
- `Sources/Services/CodexHookInstaller.swift`：Codex hook 列表恢复 `SubagentStart`。
- `Sources/Stores/SessionStore.swift`：追踪 subagent Start/Stop、统一 idle/end 清理、通知切换器刷新。
- `Sources/Views/Overlay/SessionSwitcherView.swift`：绘制最多 5 条橙色短横线。
- `Tests/HookInstallerEventsTests.swift`：验证 Claude Code hook 列表成对包含 Start/Stop。
- `Tests/CodexHookInstallerTests.swift`：验证 Codex 安装配置成对包含 Start/Stop。
- `Tests/SessionStoreSubagentTests.swift`：验证计数幂等、精确删除、新 session、idle/end/超时清理。
- `Tests/SessionSwitcherStoreTests.swift`：验证切换器打开期间 refresh 能更新 subagent 数量并保持当前选择。
- `CLAUDE.md`：记录 SubagentStart/Stop 成对追踪和 idle 清理策略。

---

### Task 1: 恢复成对的 Subagent hook 注册

**Files:**
- Create: `Tests/HookInstallerEventsTests.swift`
- Modify: `Tests/CodexHookInstallerTests.swift:19-34`
- Modify: `Sources/Services/HookInstaller.swift:12-31`
- Modify: `Sources/Services/CodexHookInstaller.swift:9-20`
- Modify: `CLAUDE.md` 的 hooks 数据流说明

**Interfaces:**
- Consumes: `HookInstaller.hookEvents: [String]`、`CodexHookInstaller.hookEvents: [String]`。
- Produces: 两套安装器都注册 `SubagentStart` 和 `SubagentStop`；`AppStore.start()` 已调用 `eventBus.installAll()`，因此新版启动时自动补齐已有用户配置。

- [ ] **Step 1: 写 Claude Code hook 列表失败测试**

创建 `Tests/HookInstallerEventsTests.swift`：

```swift
import XCTest
@testable import PeachyPet

final class HookInstallerEventsTests: XCTestCase {
    func testSubagentLifecycleHooksAreRegisteredAsPair() {
        XCTAssertTrue(HookInstaller.hookEvents.contains("SubagentStart"))
        XCTAssertTrue(HookInstaller.hookEvents.contains("SubagentStop"))
    }
}
```

该测试要求把 `HookInstaller.hookEvents` 从 `private static let` 改为模块内可见的 `static let`；功能行为不变，只提供与 `CodexHookInstaller.hookEvents` 一致的测试入口。

- [ ] **Step 2: 在 Codex 安装测试中增加显式成对断言**

在 `Tests/CodexHookInstallerTests.swift` 的 `testInstallCreatesAllEventsPointingToScript()` 末尾增加：

```swift
XCTAssertTrue(CodexHookInstaller.hookEvents.contains("SubagentStart"))
XCTAssertTrue(CodexHookInstaller.hookEvents.contains("SubagentStop"))
```

保留现有逐事件配置校验，它会继续验证实际写出的 `hooks.json` 包含两项并指向 PeachyPet 脚本。

- [ ] **Step 3: 运行测试确认失败**

Run:

```bash
swift test --filter 'HookInstallerEventsTests|CodexHookInstallerTests.testInstallCreatesAllEventsPointingToScript'
```

Expected: `HookInstallerEventsTests` 无法访问私有 `hookEvents`，或恢复可见性后因缺少 `SubagentStart` 断言失败。

- [ ] **Step 4: 恢复 Claude Code 的 SubagentStart**

将 `Sources/Services/HookInstaller.swift` 的列表和注释改为：

```swift
/// All Claude Code event types we want to subscribe to.
/// Deliberately omitted vs a naive "subscribe to all":
///   PostToolUse — phase transition identical to PreToolUse (.running); pure noise
///   PostCompact — phase transition to .running already covered by subsequent PreToolUse/UserPromptSubmit
///   StopFailure — treated identically to Stop in SessionStore; rare enough not to warrant a separate hook
///   ConfigChange / TeammateIdle / WorktreeCreate / WorktreeRemove — no downstream handler, zero UI effect
/// SubagentStart and SubagentStop must remain paired so active subagents can be tracked by agentId.
static let hookEvents = [
    "PreToolUse",
    "PostToolUseFailure",
    "Stop",
    "Notification",
    "SessionStart",
    "SessionEnd",
    "TaskCompleted",
    "PermissionRequest",
    "UserPromptSubmit",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
]
```

- [ ] **Step 5: 恢复 Codex 的 SubagentStart**

将 `Sources/Services/CodexHookInstaller.swift` 对应部分改为：

```swift
/// Codex-supported events we subscribe to (camelCase, matches Codex 0.144.5).
/// PostToolUse and PostCompact omitted — same reasoning as Claude hooks:
/// phase transitions are already covered by PreToolUse and subsequent events.
/// SubagentStart and SubagentStop remain paired for exact active-subagent tracking.
static let hookEvents = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "Stop",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
]
```

- [ ] **Step 6: 更新项目协作文档**

在 `CLAUDE.md` 的 Claude hooks/Codex 数据流附近增加简短说明：

```markdown
### Subagent 状态追踪

- Claude Code 与 Codex 必须成对注册 `SubagentStart` / `SubagentStop`。
- `SessionStore` 按 `sessionId + agentId` 追踪活跃 subagent；session 进入 idle/end 时强制清零，防止漏事件残留。
```

- [ ] **Step 7: 运行测试确认通过**

Run:

```bash
swift test --filter 'HookInstallerEventsTests|CodexHookInstallerTests.testInstallCreatesAllEventsPointingToScript'
```

Expected: 2 个目标测试通过，0 failures。

- [ ] **Step 8: 小步提交**

```bash
git add Sources/Services/HookInstaller.swift Sources/Services/CodexHookInstaller.swift Tests/HookInstallerEventsTests.swift Tests/CodexHookInstallerTests.swift CLAUDE.md
git commit -m "fix: 恢复 subagent 生命周期 hook 追踪"
```

---

### Task 2: 让 SessionStore 精确追踪并统一清理 subagent

**Files:**
- Create: `Tests/SessionStoreSubagentTests.swift`
- Modify: `Sources/Stores/SessionStore.swift:225-243, 349-390, 440-469, 503-525, 534-577, 610-742`

**Interfaces:**
- Consumes: `AgentEvent.agentId`、`HookEventType.subagentStart`、`HookEventType.subagentStop`。
- Produces: `AgentSession.activeSubagentCount` 始终等于当前已知活跃 subagent 数量；所有 idle/end 路径都归零；计数变化调用 `onPhasesChanged` 刷新已打开的切换器。

- [ ] **Step 1: 写 subagent 事件测试 helper 和核心失败测试**

创建 `Tests/SessionStoreSubagentTests.swift`：

```swift
import XCTest
@testable import PeachyPet

@MainActor
final class SessionStoreSubagentTests: XCTestCase {
    private func makeStore(idleRetention: TimeInterval = 300) -> SessionStore {
        SessionStore(idleRetentionDuration: idleRetention)
    }

    private func event(
        _ type: HookEventType,
        sessionId: String,
        agentId: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: type.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/subagent-test",
            source: "claude-code",
            agentId: agentId
        )
    }

    func testDistinctStartsCountAndDuplicateStartIsIdempotent() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "subagents-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "B"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.activeSubagentCount, 2)
        XCTAssertEqual(session?.phase, .running)
    }

    func testStopRemovesExactAgentAndUnknownStopDoesNotChangeCount() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "subagent-stop-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "B"))
        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "unknown"))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 2)

        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))

        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 1)
    }

    func testAnonymousAndIdentifiedSubagentsAreCountedTogether() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "mixed-subagents-\(UUID().uuidString)"

        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 2)

        store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 1)

        store.recordEvent(event(.subagentStop, sessionId: sid))
        XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.activeSubagentCount, 0)
    }

    func testSubagentStartCreatesRunningSessionWhenSessionStartWasMissed() {
        let store = makeStore()
        defer { store.stopTimers() }
        let sid = "subagent-first-\(UUID().uuidString)"

        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))

        let session = store.sessions.first(where: { $0.id == sid })
        XCTAssertEqual(session?.status, .active)
        XCTAssertEqual(session?.phase, .running)
        XCTAssertEqual(session?.activeSubagentCount, 1)
    }
}
```

- [ ] **Step 2: 写 idle/end/超时清理失败测试**

继续在同一测试类加入：

```swift
func testStopStopFailureAndSessionEndClearSubagents() {
    for terminalEvent in [HookEventType.stop, .stopFailure, .sessionEnd] {
        let store = makeStore()
        let sid = "clear-\(terminalEvent.rawValue)-\(UUID().uuidString)"
        store.recordEvent(event(.sessionStart, sessionId: sid))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
        store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "B"))

        store.recordEvent(event(terminalEvent, sessionId: sid))

        XCTAssertEqual(
            store.sessions.first(where: { $0.id == sid })?.activeSubagentCount,
            0,
            "\(terminalEvent.rawValue) must clear subagents"
        )
        store.stopTimers()
    }
}

func testIdleExpiryClearsSubagents() {
    let store = makeStore(idleRetention: 0)
    defer { store.stopTimers() }
    let sid = "expire-subagents-\(UUID().uuidString)"

    store.recordEvent(event(.sessionStart, sessionId: sid))
    store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
    store.recordEvent(event(.stop, sessionId: sid))
    store.expireIdleSessions()

    let session = store.sessions.first(where: { $0.id == sid })
    XCTAssertEqual(session?.status, .ended)
    XCTAssertEqual(session?.activeSubagentCount, 0)
}

func testStartupMigrationClearsSubagentsFromExpiredSession() {
    let store = makeStore(idleRetention: 0)
    defer { store.stopTimers() }
    let sid = "migrate-subagents-\(UUID().uuidString)"
    var session = AgentSession(
        id: sid,
        projectDir: "/tmp/subagent-test",
        projectName: "subagent-test",
        agentSource: .claudeCode,
        status: .active,
        phase: .idle,
        eventCount: 1,
        startedAt: Date(timeIntervalSinceNow: -10),
        lastEventAt: Date(timeIntervalSinceNow: -10),
        activeSubagentCount: 3
    )
    session.idleUntil = Date(timeIntervalSinceNow: -1)
    store.injectSessionForTesting(session)

    store.runStartupMigration()

    let migrated = store.sessions.first(where: { $0.id == sid })
    XCTAssertEqual(migrated?.status, .ended)
    XCTAssertEqual(migrated?.activeSubagentCount, 0)
}

func testStartupMigrationClearsPersistedCountWithoutAgentIds() {
    let store = makeStore(idleRetention: 300)
    defer { store.stopTimers() }
    let sid = "restart-subagents-\(UUID().uuidString)"
    let session = AgentSession(
        id: sid,
        projectDir: "/tmp/subagent-test",
        projectName: "subagent-test",
        agentSource: .claudeCode,
        status: .active,
        phase: .running,
        eventCount: 1,
        startedAt: Date(),
        lastEventAt: Date(),
        activeSubagentCount: 3,
        terminalPid: Int(ProcessInfo.processInfo.processIdentifier)
    )
    store.injectSessionForTesting(session)

    store.runStartupMigration()

    let migrated = store.sessions.first(where: { $0.id == sid })
    XCTAssertEqual(migrated?.status, .active)
    XCTAssertEqual(migrated?.activeSubagentCount, 0)
}
```

第二个测试保护重启语义：`activeSubagentCount` 会从 JSON 解码，但 `activeSubagentIds` 是纯内存集合，不能把无法验证的旧计数继续显示。

- [ ] **Step 3: 写实时刷新回调失败测试**

继续加入：

```swift
func testSubagentCountChangeNotifiesObservers() {
    let store = makeStore()
    defer { store.stopTimers() }
    let sid = "notify-subagents-\(UUID().uuidString)"
    var notifications = 0
    store.onPhasesChanged = { notifications += 1 }

    store.recordEvent(event(.sessionStart, sessionId: sid))
    notifications = 0
    store.recordEvent(event(.subagentStart, sessionId: sid, agentId: "A"))
    store.recordEvent(event(.subagentStop, sessionId: sid, agentId: "A"))

    XCTAssertEqual(notifications, 2)
}
```

- [ ] **Step 4: 运行测试确认失败**

Run:

```bash
swift test --filter SessionStoreSubagentTests
```

Expected: 新 session 的 `SubagentStart` 仍创建 idle/count 0；`Stop` 不清空集合；Start/Stop 不触发刷新回调，测试失败。

- [ ] **Step 5: 增加统一清理函数**

在现有 `activeSubagentIds` 旁增加匿名事件计数：

```swift
private var anonymousSubagentCounts: [String: Int] = [:]
```

在 `SessionStore` 中增加：

```swift
private func updateSubagentCount(at index: Int) {
    guard sessions.indices.contains(index) else { return }
    let sessionId = sessions[index].id
    let identifiedCount = activeSubagentIds[sessionId]?.count ?? 0
    let anonymousCount = anonymousSubagentCounts[sessionId] ?? 0
    sessions[index].activeSubagentCount = identifiedCount + anonymousCount
}

private func clearSubagents(at index: Int) {
    guard sessions.indices.contains(index) else { return }
    let sessionId = sessions[index].id
    activeSubagentIds.removeValue(forKey: sessionId)
    anonymousSubagentCounts.removeValue(forKey: sessionId)
    sessions[index].activeSubagentCount = 0
}
```

具名集合和匿名计数分开维护，避免混合事件发生时其中一类覆盖另一类。

- [ ] **Step 6: 修正现有 session 的状态机**

在 `recordEvent` 开头增加局部标记：

```swift
var shouldNotifyObservers = false
```

将相关 case 改为：

```swift
case .stop, .stopFailure:
    sessions[index].phase = .idle
    clearSubagents(at: index)
    setIdleUntil(for: sessionId)
    shouldNotifyObservers = true
    PeachyLog.session.debug("Session idle (Stop): \(sessionId) idleUntil=+\(Int(self.idleRetentionDuration))s")

case .sessionEnd:
    PeachyLog.session.info("Session ended (SessionEnd): \(sessionId)")
    sessions[index].status = .ended
    sessions[index].phase = .idle
    clearSubagents(at: index)
    shouldNotifyObservers = true

case .subagentStart:
    sessions[index].phase = .running
    clearIdleUntil(for: sessionId)
    let previousCount = sessions[index].activeSubagentCount
    if let agentId = event.agentId {
        var ids = activeSubagentIds[sessionId] ?? []
        ids.insert(agentId)
        activeSubagentIds[sessionId] = ids
    } else {
        anonymousSubagentCounts[sessionId, default: 0] += 1
    }
    updateSubagentCount(at: index)
    shouldNotifyObservers = sessions[index].activeSubagentCount != previousCount

case .subagentStop:
    let previousCount = sessions[index].activeSubagentCount
    if let agentId = event.agentId {
        activeSubagentIds[sessionId]?.remove(agentId)
    } else {
        anonymousSubagentCounts[sessionId] = max(0, (anonymousSubagentCounts[sessionId] ?? 0) - 1)
    }
    updateSubagentCount(at: index)
    shouldNotifyObservers = sessions[index].activeSubagentCount != previousCount
```

`SubagentStop` 不主动把 idle session 改回 running；正常顺序中 session 本来就是 running，乱序的晚到 Stop 也不会复活已 idle 的 session。

删除原来 `SessionEnd` case 内直接调用的 `onPhasesChanged?()`，统一在持久化之后通知：

```swift
persist()
if shouldNotifyObservers {
    onPhasesChanged?()
}
```

- [ ] **Step 7: 处理缺失 SessionStart 时直接收到 SubagentStart**

在创建新 session 的分支中，把 phase 计算改为：

```swift
let startsRunning = event.eventType == .userPromptSubmit || event.eventType == .subagentStart
let phase: AgentSession.Phase = startsRunning ? .running : .idle
```

创建 session 后补充：

```swift
if event.eventType == .subagentStart {
    if let agentId = event.agentId {
        activeSubagentIds[sessionId] = [agentId]
    } else {
        anonymousSubagentCounts[sessionId] = 1
    }
    session.activeSubagentCount = 1
    shouldNotifyObservers = true
}
```

然后再 `sessions.insert(session, at: 0)`。

- [ ] **Step 8: 在所有 idle/end 路径调用统一清理**

逐项替换直接的 `activeSubagentCount = 0` 或补上缺失清理：

```swift
// interrupt detection: phase = idle 后
self.clearSubagents(at: candidate.index)

// applyReconciliation 的两个 ended 分支
clearSubagents(at: i)

// expireIdleSessions 的 explicit/implicit 两个 ended 分支
clearSubagents(at: i)

// runStartupMigration：进入循环后先清除每个 active session 从 JSON 恢复的旧计数，
// 因为两类内存追踪状态都不持久化，重启后这些计数已无法验证
let hadPersistedSubagents = sessions[i].activeSubagentCount > 0
clearSubagents(at: i)
if hadPersistedSubagents { changed = true }

// runStartupMigration 的三个 ended 分支继续按原逻辑结束 session
```

在 `rollbackInternalTurn` 删除 session 前清理映射：

```swift
if !snapshot.existed {
    activeSubagentIds.removeValue(forKey: sessionId)
    anonymousSubagentCounts.removeValue(forKey: sessionId)
    sessions.removeAll(where: { $0.id == sessionId })
    // existing logging/persist
}
```

以及 approval-only phantom 删除分支：

```swift
activeSubagentIds.removeValue(forKey: sessionId)
anonymousSubagentCounts.removeValue(forKey: sessionId)
sessions.remove(at: index)
```

- [ ] **Step 9: 运行聚焦测试确认通过**

Run:

```bash
swift test --filter SessionStoreSubagentTests
```

Expected: 所有 `SessionStoreSubagentTests` 通过，0 failures。

- [ ] **Step 10: 运行 SessionStore 回归测试**

Run:

```bash
swift test --filter 'SessionStoreIdleTests|SessionStoreProcessMatchersTests'
```

Expected: 现有 SessionStore 测试全部通过，0 failures。

- [ ] **Step 11: 小步提交**

```bash
git add Sources/Stores/SessionStore.swift Tests/SessionStoreSubagentTests.swift
git commit -m "fix: 精确追踪并清理 subagent 状态"
```

---

### Task 3: 在会话切换器绘制橙色短横线

**Files:**
- Create: `Tests/SessionSwitcherStoreTests.swift`
- Modify: `Sources/Views/Overlay/SessionSwitcherView.swift:55-155`

**Interfaces:**
- Consumes: `AgentSession.activeSubagentCount`、`Constants.orangePrimary`、`SessionSwitcherStore.refresh(sessions:)`。
- Produces: `SessionSwitcherRow` 在名称/状态下方显示 `min(activeSubagentCount, 5)` 条短横线；已打开切换器能通过 refresh 获得最新计数。

- [ ] **Step 1: 写切换器实时 refresh 失败保护测试**

创建 `Tests/SessionSwitcherStoreTests.swift`：

```swift
import XCTest
@testable import PeachyPet

@MainActor
final class SessionSwitcherStoreTests: XCTestCase {
    private func session(id: String, subagents: Int, date: Date) -> AgentSession {
        AgentSession(
            id: id,
            projectDir: "/tmp/\(id)",
            projectName: id,
            agentSource: .claudeCode,
            status: .active,
            phase: .running,
            eventCount: 1,
            startedAt: date,
            lastEventAt: date,
            activeSubagentCount: subagents
        )
    }

    func testRefreshUpdatesSubagentCountAndPreservesSelection() {
        let store = SessionSwitcherStore()
        let now = Date()
        store.open(sessions: [
            session(id: "A", subagents: 0, date: now),
            session(id: "B", subagents: 0, date: now.addingTimeInterval(-1)),
        ])
        store.selectIndex(1)

        store.refresh(sessions: [
            session(id: "A", subagents: 3, date: now),
            session(id: "B", subagents: 2, date: now.addingTimeInterval(-1)),
        ])

        XCTAssertEqual(store.selectedSession?.id, "B")
        XCTAssertEqual(store.selectedSession?.activeSubagentCount, 2)
        XCTAssertEqual(store.sessions.first(where: { $0.id == "A" })?.activeSubagentCount, 3)
        store.close()
    }
}
```

该测试应在现有实现上通过；它作为回归保护，证明 `onPhasesChanged → refresh` 这条实时 UI 数据链不会丢失值类型更新。

- [ ] **Step 2: 运行 refresh 测试建立绿色基线**

Run:

```bash
swift test --filter SessionSwitcherStoreTests
```

Expected: 1 test passed, 0 failures。

- [ ] **Step 3: 在 SessionSwitcherRow 中加入短横线**

把项目名称/状态的 `VStack` 改为：

```swift
VStack(alignment: .leading, spacing: 1) {
    Text(projectLabel)
        .font(Constants.body(size: 11, weight: .medium))
        .foregroundStyle(Constants.textPrimary)
        .lineLimit(1)

    HStack(spacing: 4) {
        Text(phaseLabel)
        if let ago = relativeTime {
            Text("·")
            Text(ago)
        }
    }
    .font(Constants.body(size: 9))
    .foregroundStyle(Constants.textMuted)

    if visibleSubagentCount > 0 {
        HStack(spacing: 4) {
            ForEach(0..<visibleSubagentCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(Constants.orangePrimary)
                    .frame(width: 10, height: 2.5)
            }
        }
        .padding(.top, 2)
        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
    }
}
.animation(.easeInOut(duration: 0.15), value: visibleSubagentCount)
```

在 `SessionSwitcherRow` 的私有计算属性中增加：

```swift
private var visibleSubagentCount: Int {
    min(max(session.activeSubagentCount, 0), 5)
}
```

不为 0 数量保留占位空间；仅有 subagent 的行会自然增加短横线所需高度。

- [ ] **Step 4: 编译验证 SwiftUI 代码**

Run:

```bash
swift build
```

Expected: `Build complete!`，无 Swift 编译错误。

- [ ] **Step 5: 运行相关测试**

Run:

```bash
swift test --filter 'SessionSwitcherStoreTests|SessionStoreSubagentTests'
```

Expected: 全部通过，0 failures。

- [ ] **Step 6: 小步提交**

```bash
git add Sources/Views/Overlay/SessionSwitcherView.swift Tests/SessionSwitcherStoreTests.swift
git commit -m "feature: 会话切换器显示 subagent 状态短横线"
```

---

### Task 4: 全量验证、迁移本机 hooks 并安装 release

**Files:**
- No source changes expected.
- Runtime config updated by app startup: `~/.claude/settings.json`、`~/.codex/hooks.json`。

**Interfaces:**
- Consumes: Task 1-3 的全部实现。
- Produces: 绿色测试、已安装的 `/Applications/PeachyPet.app`、本机 SubagentStart hooks 已补齐、可进行真实视觉验收。

- [ ] **Step 1: 检查提交边界和未提交文件**

Run:

```bash
git status --short
git log -4 --oneline
```

Expected:

- 本功能有 3 个小提交。
- `Sources/Utilities/IDETerminalFocus.swift` 仍保持原有未提交状态，未出现在任何 subagent 功能提交中。
- `.codex/` 等既有未跟踪文件未被提交。

- [ ] **Step 2: 运行全量单元测试**

Run:

```bash
swift test
```

Expected: 全部测试通过，0 failures。

- [ ] **Step 3: 构建并安装 release**

Run:

```bash
bash scripts/build-app.sh dist
pkill -x PeachyPet 2>/dev/null; sleep 1
rm -rf /Applications/PeachyPet.app
cp -R dist/PeachyPet.app /Applications/PeachyPet.app
open /Applications/PeachyPet.app
```

Expected: 签名验证通过，应用从 `/Applications` 启动。

- [ ] **Step 4: 验证启动迁移已补齐 hooks**

Run:

```bash
python3 - <<'PY'
import json, os
for path in ['~/.claude/settings.json', '~/.codex/hooks.json']:
    p = os.path.expanduser(path)
    data = json.load(open(p))
    hooks = data.get('hooks', {})
    print(path, 'SubagentStart=', 'SubagentStart' in hooks, 'SubagentStop=', 'SubagentStop' in hooks)
PY
```

Expected:

```text
~/.claude/settings.json SubagentStart= True SubagentStop= True
~/.codex/hooks.json SubagentStart= True SubagentStop= True
```

- [ ] **Step 5: 真实 UI 验收**

在 Claude Code 发起一个会启动多个 subagent 的任务，并在运行期间双击 Cmd 打开 session switcher，检查：

1. 第一个 subagent Start 后出现 1 条橙色短横线。
2. 并发 subagent 增加时依次显示，最多 5 条。
3. 单个 SubagentStop 后减少对应数量。
4. session 进入 idle 后所有短横线立即消失。
5. 没有 subagent 的行高度、文本、图标、快捷键 badge 与当前版本一致。
6. `SubagentStop` 不弹 `Task Completed`。

若 UI 无法在当前自动化环境中触发，必须明确报告“编译与状态测试通过，真实视觉验收待用户触发”，不能声称已视觉验证。

- [ ] **Step 6: 确认无需额外提交**

Run:

```bash
git status --short
```

Expected: 只剩任务开始前已有的 `IDETerminalFocus.swift` 和既有未跟踪文件；没有本功能遗漏的源文件或测试文件。
