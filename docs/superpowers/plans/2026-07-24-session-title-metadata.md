# SessionSwitcher 会话标题近实时同步实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SessionSwitcher 中显示项目名与会话标题，并在 Claude `/rename`、Codex CLI/Desktop 改名或 Desktop 项目名变化后 1–2 秒内刷新。

**Architecture:** 将 provider-specific metadata 解析隔离在 `SessionMetadataMonitor` 及其纯解析辅助类型中。`SessionStore` 只负责按 sessionId 保存 metadata，`SessionSwitcherView` 只负责展示统一的 `AgentSession` 字段。Claude transcript、Codex session index 和 Codex global state 都由 monitor 定期增量检查，UI 不直接读磁盘。

**Tech Stack:** Swift 5.9+, SwiftUI/Observation, XCTest, Foundation FileManager/Timer, Swift Package Manager.

## Execution Precondition

`Sources/Stores/SessionStore.swift`, `Sources/Stores/AppStore.swift`, and `Sources/Views/Overlay/OverlayManager.swift` currently contain unrelated uncommitted Esc/session/hook work. Before executing this plan, either:

1. finish and commit those existing changes, then implement on the resulting clean branch; or
2. create an isolated worktree from the intended base and keep all title-feature commits there until the existing work is integrated.

Do not execute this plan in the current dirty checkout and do not use whole-file `git add` on overlapping files until the precondition is satisfied.

## Global Constraints

- 正式标题优先于首条用户任务回退。
- Codex Desktop 手动项目名只覆盖项目显示名，不覆盖会话标题。
- 不解析 iTerm2/终端窗口标题，不使用 Claude slug 作为人类标题。
- metadata 文件损坏或暂时不可读时保留已有值。
- 只处理活跃 session，不扫描全量历史 session。
- metadata 更新不得改变 session status、phase、lastEventAt、排序或 activeSubagentCount。
- 保持现有未提交的 Esc/session/hook 修改不变，不在本功能提交中暂存它们。
- 每个任务完成后运行该任务的定向测试，再提交该任务涉及的文件。

---

### Task 1: 扩展事件与会话 metadata 模型

**Files:**
- Modify: `Sources/Models/AgentEvent.swift:5-42,106-162`
- Modify: `Sources/Stores/SessionStore.swift:4-145` (`AgentSession` model only in this task)
- Create: `Tests/AgentEventTitleMetadataTests.swift`
- Create: `Tests/SessionStoreMetadataTests.swift`

**Interfaces:**
- Produces `AgentEvent.prompt: String?` decoded from `prompt` for `UserPromptSubmit` payloads.
- Produces `AgentSession.sessionTitle: String?`, `projectDisplayName: String?`, and `firstUserPrompt: String?`, all Codable with nil defaults for old `sessions.json` records.
- Produces `AgentSession.displayProjectName` and `displaySessionTitle` computed fallbacks without touching UI-specific disk access.

- [ ] **Step 1: Add failing model tests**

Add tests for:

```swift
func testAgentEventDecodesUserPrompt() throws
func testAgentSessionDisplayUsesProjectOverrideThenProjectName()
func testAgentSessionDisplayUsesTitleThenFirstPrompt()
func testAgentSessionDisplayOmitsEmptyTitleSeparator()
```

Use JSON decoding for `AgentEvent` to prove the wire key is exactly `prompt`. Build `AgentSession` values with and without the new fields and assert:

```swift
XCTAssertEqual(session.displayProjectName, "namiwork-core")
XCTAssertEqual(session.displaySessionTitle, "解决 release 分支冲突")
XCTAssertNil(session.displaySessionTitle)
```

- [ ] **Step 2: Run model tests and verify RED**

Run:

```bash
swift test --filter 'AgentEventTitleMetadataTests|SessionStoreMetadataTests/testAgentSessionDisplay'
```

Expected: compile failure because the new fields and computed properties do not exist.

- [ ] **Step 3: Implement the model fields**

Add `prompt` to `AgentEvent`’s stored properties and CodingKeys/decoder path. Add the three optional mutable metadata fields to `AgentSession`, add them to its initializer with nil defaults, and update Codable decoding so old records without those keys still load.

Implement these computed properties:

```swift
var displayProjectName: String {
    projectDisplayName ?? projectName ?? projectDir.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session"
}

var displaySessionTitle: String? {
    let value = sessionTitle ?? firstUserPrompt
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
}
```

- [ ] **Step 4: Preserve the existing Claude hook transport**

Do not modify `HookInstaller`: `UserPromptSubmit` is already registered and the hook script already forwards stdin unchanged. The implementation change is limited to retaining the existing `prompt` key in `AgentEvent`.

- [ ] **Step 5: Run model tests and verify GREEN**

Run:

```bash
swift test --filter 'AgentEventTitleMetadataTests|SessionStoreMetadataTests/testAgentSessionDisplay'
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 1**

Stage only the model/event files and their tests:

```bash
git add "Sources/Models/AgentEvent.swift" "Sources/Stores/SessionStore.swift" "Tests/AgentEventTitleMetadataTests.swift" "Tests/SessionStoreMetadataTests.swift"
git commit -m "$(cat <<'EOF'
feature: 扩展会话标题 metadata 模型
EOF
)"
```

---

### Task 2: Implement provider metadata parsers and monitor

**Files:**
- Create: `Sources/Services/SessionMetadataMonitor.swift`
- Test: `Tests/SessionMetadataMonitorTests.swift`
- Test fixtures: keep inline JSON strings in the test file; do not add user home data to the repository.

**Interfaces:**
- Produces pure parsing helpers:

```swift
struct SessionTitleMetadata: Equatable {
    let sessionId: String
    let title: String?
}

struct SessionProjectMetadata: Equatable {
    let sessionId: String
    let projectName: String?
}

struct SessionMetadataUpdate: Equatable {
    let sessionId: String
    let sessionTitle: String?
    let firstUserPrompt: String?
    let projectDisplayName: String?
}
```

- Produces monitor lifecycle:

```swift
final class SessionMetadataMonitor {
    init(
        homeDirectory: String = NSHomeDirectory(),
        pollInterval: TimeInterval = 1.0,
        onUpdate: @escaping (SessionMetadataUpdate) -> Void
    )
    func start(activeSessions: [AgentSession])
    func update(activeSessions: [AgentSession])
    func stop()
}
```

- [ ] **Step 1: Write parser tests first**

Add tests covering:

```swift
func testClaudeLastCustomTitleWins()
func testClaudePromptFallbackUsesFirstPromptOnly()
func testCodexLastThreadNameWinsForSameId()
func testCodexThreadIdsDoNotCrossWire()
func testCodexDesktopProjectAssignmentMapsName()
func testMalformedGlobalStatePreservesNoUpdate()
```

Use representative inline records:

```json
{"type":"custom-title","customTitle":"旧标题","sessionId":"claude-1"}
{"type":"custom-title","customTitle":"新标题","sessionId":"claude-1"}
```

and:

```json
{"id":"codex-1","thread_name":"旧标题","updated_at":"2026-07-24T10:00:00Z"}
{"id":"codex-1","thread_name":"新标题","updated_at":"2026-07-24T10:01:00Z"}
```

For global state, assert `thread-project-assignments["codex-1"].projectId` resolves through `local-projects[projectId].name`.

- [ ] **Step 2: Run parser tests and verify RED**

Run:

```bash
swift test --filter SessionMetadataMonitorTests
```

Expected: compile failure because the parser/monitor types do not exist.

- [ ] **Step 3: Implement pure parsers**

In `SessionMetadataMonitor.swift`, implement JSONL parsing using `JSONSerialization` or small Codable structs. Requirements:

- Skip malformed JSONL lines without aborting the file.
- For Claude, accept only records with matching `sessionId` and `type == "custom-title"`; the last valid record wins.
- For Codex, accept the last record for each matching `id`; later append order wins.
- For first prompt, trim whitespace and keep only the first non-empty prompt per session.
- For global state, safely unwrap dictionaries and return no update on malformed input; never convert malformed data into an empty project name.

- [ ] **Step 4: Implement 1-second active-session monitor**

Use a main-thread `Timer` at 1.0 seconds. On `start(activeSessions:)`, perform an initial scan from byte zero for each active provider metadata file so existing titles and first prompts appear immediately, then store the resulting offsets. On each later tick:

1. Read the current active session IDs supplied by `update(activeSessions:)`.
2. For each active session with `transcriptPath`, read only newly appended transcript bytes using a per-path offset. Parse Claude `custom-title` and initial user content; parse Codex `user_message` when `firstUserPrompt` is still missing.
3. Read `~/.codex/session_index.jsonl` incrementally and map matching `id` values.
4. Check `.codex/.codex-global-state.json` mtime; if changed, reread the complete file and resolve active thread assignments.
5. Emit only non-empty or changed values via `onUpdate`.

When a file is atomically replaced or truncated, reset its offset and reread from byte zero. `stop()` must invalidate the timer and clear offsets.

- [ ] **Step 5: Test monitor lifecycle and file changes**

Add tests using a temporary directory that verify:

```swift
func testMonitorReadsClaudeRenameAfterStart()
func testMonitorReadsCodexThreadRenameAfterStart()
func testMonitorReadsDesktopProjectNameAfterGlobalStateReplacement()
func testMonitorStopsWithoutFurtherUpdates()
```

Use a temporary directory and initialize the monitor with `pollInterval: 0.01` for deterministic tests. Assert updates are keyed by exact sessionId.

- [ ] **Step 6: Run monitor tests and verify GREEN**

Run:

```bash
swift test --filter SessionMetadataMonitorTests
```

Expected: all parser, lifecycle, rename, and project assignment tests pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add "Sources/Services/SessionMetadataMonitor.swift" "Tests/SessionMetadataMonitorTests.swift"
git commit -m "$(cat <<'EOF'
feature: 增加会话标题 metadata 监听
EOF
)"
```

---

### Task 3: Persist metadata through SessionStore and AppStore

**Files:**
- Modify: `Sources/Stores/SessionStore.swift:4-78,704-887`
- Modify: `Sources/Stores/AppStore.swift` initialization/start/stop wiring
- Test: `Tests/SessionStoreMetadataTests.swift`

**Interfaces:**
- Produces:

```swift
func updateMetadata(_ update: SessionMetadataUpdate)
```

- Consumes: `SessionMetadataMonitor` updates and `AgentEvent.prompt` from `UserPromptSubmit`.

- [ ] **Step 1: Write failing SessionStore tests**

Add tests:

```swift
func testFirstUserPromptIsStoredOnlyOnce()
func testMetadataUpdateChangesOnlyMetadataFields()
func testMetadataUpdatePersistsAndReloads()
func testMetadataForUnknownSessionIsIgnored()
```

For `testMetadataUpdateChangesOnlyMetadataFields`, capture phase/status/lastEventAt/subagent count before update and assert they are unchanged afterward.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter SessionStoreMetadataTests
```

Expected: compile failure because `updateMetadata` and metadata fields are not wired into SessionStore.

- [ ] **Step 3: Implement SessionStore metadata updates**

When `recordEvent(_:)` receives a non-empty `AgentEvent.prompt`, set `firstUserPrompt` only if the session has none. Do not overwrite it on subsequent user prompts.

Implement `updateMetadata(_:)`:

- Find by exact sessionId.
- Apply only non-empty incoming values.
- Preserve existing fields when incoming metadata is nil/empty.
- Call `persist()` and `onPhasesChanged?()` only when a value actually changes.
- Do not mutate phase/status/lastEventAt/eventCount/sorting fields.

Update any `AgentSession` construction/copy paths to carry the three metadata fields.

- [ ] **Step 4: Wire monitor lifecycle**

Create `SessionMetadataMonitor` in AppStore with callback:

```swift
{ [weak self] update in
    self?.sessionStore.updateMetadata(update)
}
```

Start it after the initial stores/session restore completes. Call `update(activeSessions:)` whenever sessions change. Stop it from AppStore shutdown/stop paths. Keep the monitor on the main actor because SessionStore and SwiftUI observation are main-thread state.

- [ ] **Step 5: Run SessionStore metadata tests and verify GREEN**

Run:

```bash
swift test --filter SessionStoreMetadataTests
```

Expected: all persistence, first-prompt, unknown-session, and field-isolation tests pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add "Sources/Stores/SessionStore.swift" "Sources/Stores/AppStore.swift" "Tests/SessionStoreMetadataTests.swift"
git commit -m "$(cat <<'EOF'
feature: 持久化会话标题 metadata
EOF
)"
```

---

### Task 4: Display project name and session title in SessionSwitcher

**Files:**
- Modify: `Sources/Views/Overlay/SessionSwitcherView.swift:88-161`
- Create: `Tests/SessionSwitcherTitleTests.swift`

**Interfaces:**
- Consumes: `AgentSession.displayProjectName` and `displaySessionTitle` from Task 1.
- Produces: first row line formatted as `projectDisplayName · sessionTitle` with one-line truncation.

- [ ] **Step 1: Write display formatting tests**

Add pure helper tests for:

```swift
func testProjectAndTitleUseMiddleDot()
func testProjectOnlyOmitsMiddleDot()
```

Keep formatting in this internal top-level helper so tests do not need to instantiate an AppKit window:

```swift
func formatSessionSwitcherProjectLabel(project: String, title: String?) -> String {
    guard let title, !title.isEmpty else { return project }
    return "\(project) · \(title)"
}
```

Assert:

```swift
XCTAssertEqual(formatSessionSwitcherProjectLabel(project: "namiwork-core", title: "解决 release 分支冲突"), "namiwork-core · 解决 release 分支冲突")
XCTAssertEqual(formatSessionSwitcherProjectLabel(project: "namiwork-core", title: nil), "namiwork-core")
```

- [ ] **Step 2: Run UI/helper tests and verify RED**

Run:

```bash
swift test --filter SessionSwitcherTitleTests
```

Expected: compile failure because the helper and metadata-aware label do not exist.

- [ ] **Step 3: Implement layout-only UI change**

Replace `projectLabel` with metadata-aware formatting:

```swift
private var projectLabel: String {
    formatSessionSwitcherProjectLabel(
        project: session.displayProjectName,
        title: session.displaySessionTitle
    )
}
```

Keep the existing `Text(projectLabel).lineLimit(1)`, row height, icon, shortcut badge, phase line, and subagent indicator unchanged.

- [ ] **Step 4: Run UI/helper tests and verify GREEN**

Run:

```bash
swift test --filter SessionSwitcherTitleTests
```

Expected: both formatting tests pass. The existing `Text(projectLabel).lineLimit(1)` remains unchanged and is verified during runtime visual validation in Task 5.

- [ ] **Step 5: Commit Task 4**

```bash
git add "Sources/Views/Overlay/SessionSwitcherView.swift" "Tests/SessionSwitcherTitleTests.swift"
git commit -m "$(cat <<'EOF'
feature: 在会话列表显示标题
EOF
)"
```

---

### Task 5: Full verification and runtime validation

**Files:**
- Read-only review of all Task 1–4 files.
- Modify: `CLAUDE.md` only if the implementation changes the documented session data flow as specified.

**Interfaces:**
- Consumes: all metadata model, monitor, store, and UI behavior from Tasks 1–4.
- Produces: test/build/runtime evidence and updated project guidance.

- [ ] **Step 1: Run the complete Swift test suite**

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build the package**

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Launch the installed app and verify runtime behavior**

Build/install using the repository flow:

```bash
bash scripts/build-app.sh dist
pkill -x PeachyPet 2>/dev/null || true
sleep 1
rm -rf /Applications/PeachyPet.app
cp -R dist/PeachyPet.app /Applications/PeachyPet.app
open /Applications/PeachyPet.app
```

Verify the local health endpoint and use a real session switcher. Confirm:

- A Codex thread with `thread_name` displays that title.
- A Claude session with a transcript `custom-title` displays the latest title.
- A session without formal title displays the first user prompt.
- Editing the corresponding metadata file updates the visible row within two seconds.
- Desktop project name replaces the cwd basename without replacing the thread title.
- Existing icons, status, active selection, Cmd shortcuts, and row height remain unchanged.

- [ ] **Step 4: Update project guidance if needed**

If the final data flow differs from current documentation, update the Session lifecycle/data flow section of `CLAUDE.md` with:

- `AgentSession` stores `sessionTitle`, `projectDisplayName`, and `firstUserPrompt`.
- `SessionMetadataMonitor` reads Claude transcript and Codex metadata files every second for active sessions.
- Title priority is formal provider title, then first user prompt.
- Codex Desktop project name overrides only the project display name.

Do not update unrelated documentation.

- [ ] **Step 5: Run final diff checks**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intended title feature commits and pre-existing unrelated worktree changes remain.

- [ ] **Step 6: Request independent code review**

Review Tasks 1–4 as one feature. Specifically check sessionId mapping, append-only offset reset, atomic global-state replacement, metadata persistence compatibility, observer lifecycle, and UI layout regressions.

- [ ] **Step 7: Commit documentation changes if made**

If `CLAUDE.md` changed, commit it separately:

```bash
git add "CLAUDE.md"
git commit -m "$(cat <<'EOF'
docs: 补充会话标题 metadata 说明
EOF
)"
```
