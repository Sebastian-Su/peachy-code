# Waiting for Input State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Represent Claude Code `idle_prompt` as an explicit waiting-for-input session state and show a limited-duration waiting card while preserving the state in the Session Switcher.

**Architecture:** `SessionStore` owns the authoritative `.waitingInput` phase. `AppStore` maps the already-normalized `idle_prompt` event to a typed toast in `SessionFinishedStore`; the toast auto-dismisses using the existing configured duration, while the session phase remains waiting until `UserPromptSubmit`. UI rendering consumes the phase/toast type without parsing assistant text.

**Tech Stack:** Swift 5.10, SwiftUI, Observation (`@Observable`), XCTest, macOS 14+

## Global Constraints

- `Stop` remains `.idle` and still shows the existing completion card.
- Only `Notification(notification_type: "idle_prompt")` establishes `.waitingInput`.
- The waiting card reuses `taskCompletedToastDuration` (default 8 seconds).
- `UserPromptSubmit` restores `.running` and dismisses the waiting card.
- `.waitingInput` uses the existing mascot Idle animation; no animation resources change.
- English and Chinese localization must be updated together.
- Runtime verification must replace/restart the single installed `/Applications/PeachyPet.app`; do not keep a second app instance running.
- Git commits are deferred unless the user explicitly requests them.

---

## File Structure

- `Sources/Stores/SessionStore.swift` — add and transition the authoritative `.waitingInput` phase; preserve idle expiry behavior.
- `Sources/Stores/SessionFinishedStore.swift` — make floating toast content typed as completed or waiting input.
- `Sources/Stores/AppStore.swift` — map `Stop` and `idle_prompt` to their corresponding toast kinds.
- `Sources/Views/Overlay/SessionFinishedToast.swift` — render icon and localized copy by toast kind.
- `Sources/Views/Overlay/SessionSwitcherView.swift` — render `.waitingInput` as orange `Waiting for input`.
- `Sources/Views/Overlay/OverlayManager.swift` — continue treating `.waitingInput` as mascot Idle.
- `Sources/Resources/en.lproj/Localizable.strings` / `zh.lproj/Localizable.strings` — add waiting copy.
- `Tests/SessionStoreIdleTests.swift` — phase-transition and expiry regressions.
- `Tests/SessionFinishedStoreTests.swift` — typed toast and shared-duration regressions.
- `Tests/SessionSwitcherTitleTests.swift` — phase-label helper regression.
- `CLAUDE.md` — document the new session phase and `idle_prompt` transition.

---

### Task 1: Add the authoritative waiting-input session phase

**Files:**
- Modify: `Sources/Stores/SessionStore.swift:121-125, 509-530, 833-920, 924-964`
- Modify: `Tests/SessionStoreIdleTests.swift`

**Interfaces:**
- Consumes: `AgentEvent.eventType`, `AgentEvent.notificationType`, existing `setIdleUntil(for:)`, `clearIdleUntil(for:)`.
- Produces: `AgentSession.Phase.waitingInput`; `SessionStore.recordEvent(_:)` transitions `idle_prompt → waitingInput` and `UserPromptSubmit → running`.

- [ ] **Step 1: Extend the test helper to create notification events**

Change the helper in `Tests/SessionStoreIdleTests.swift` to accept `notificationType`:

```swift
private func event(
    type: HookEventType,
    sessionId: String,
    taskId: String? = nil,
    source: String = "codex-cli",
    notificationType: String? = nil
) -> AgentEvent {
    AgentEvent(
        hookEventName: type.rawValue,
        sessionId: sessionId,
        cwd: "/tmp",
        notificationType: notificationType,
        source: source,
        taskId: taskId
    )
}
```

- [ ] **Step 2: Write the failing Stop → idle_prompt transition test**

Add to `SessionStoreIdleTests`:

```swift
func testIdlePromptTransitionsStoppedSessionToWaitingInput() {
    let store = makeStore(idleRetention: 300)
    defer { store.stopTimers() }
    let sid = "waiting-\(UUID().uuidString)"

    store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))
    store.recordEvent(event(type: .stop, sessionId: sid))
    XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.phase, .idle)

    store.recordEvent(event(
        type: .notification,
        sessionId: sid,
        notificationType: "idle_prompt"
    ))

    let session = store.sessions.first(where: { $0.id == sid })
    XCTAssertEqual(session?.phase, .waitingInput)
    XCTAssertNotNil(session?.idleUntil)
}
```

- [ ] **Step 3: Write the failing waitingInput → running test**

```swift
func testUserPromptResumesWaitingInputSession() {
    let store = makeStore(idleRetention: 300)
    defer { store.stopTimers() }
    let sid = "waiting-resume-\(UUID().uuidString)"

    store.recordEvent(event(type: .stop, sessionId: sid))
    store.recordEvent(event(
        type: .notification,
        sessionId: sid,
        notificationType: "idle_prompt"
    ))
    store.recordEvent(event(type: .userPromptSubmit, sessionId: sid))

    let session = store.sessions.first(where: { $0.id == sid })
    XCTAssertEqual(session?.phase, .running)
    XCTAssertNil(session?.idleUntil)
}
```

- [ ] **Step 4: Write the failing waitingInput expiry test**

```swift
func testWaitingInputSessionExpiresWithIdleRetention() {
    let store = makeStore(idleRetention: 0)
    defer { store.stopTimers() }
    let sid = "waiting-expire-\(UUID().uuidString)"

    store.recordEvent(event(type: .stop, sessionId: sid))
    store.recordEvent(event(
        type: .notification,
        sessionId: sid,
        notificationType: "idle_prompt"
    ))
    store.expireIdleSessions()

    XCTAssertEqual(store.sessions.first(where: { $0.id == sid })?.status, .ended)
}
```

- [ ] **Step 5: Run the focused tests and verify RED**

Run:

```bash
swift test --filter SessionStoreIdleTests/testIdlePromptTransitionsStoppedSessionToWaitingInput
swift test --filter SessionStoreIdleTests/testUserPromptResumesWaitingInputSession
swift test --filter SessionStoreIdleTests/testWaitingInputSessionExpiresWithIdleRetention
```

Expected: compilation/test failure because `AgentSession.Phase.waitingInput` does not exist and `idle_prompt` has no phase transition.

- [ ] **Step 6: Add `.waitingInput` and its state transitions**

In `AgentSession.Phase`:

```swift
enum Phase: String, Codable {
    case idle
    case waitingInput
    case running
    case compacting
}
```

In the existing-session event switch inside `recordEvent(_:)`, add before `UserPromptSubmit`:

```swift
case .notification where event.notificationType == "idle_prompt":
    sessions[index].phase = .waitingInput
    if sessions[index].idleUntil == nil {
        setIdleUntil(for: sessionId)
    }
    shouldNotifyObservers = true
```

Keep the existing `UserPromptSubmit` branch unchanged so it sets `.running` and calls `clearIdleUntil(for:)`.

Unknown-session `idle_prompt` events are ignored; a waiting notification alone must not create a session without project/session context.

For a newly observed non-notification event, choose the initial phase:

```swift
if event.eventType == .notification && event.notificationType == "idle_prompt" {
    return
}
let phase: AgentSession.Phase =
    (event.eventType == .userPromptSubmit || event.eventType == .subagentStart)
        ? .running
        : .idle
```

Treat waiting sessions like idle sessions in expiry/startup migration checks:

```swift
if sessions[i].phase == .idle || sessions[i].phase == .waitingInput {
    // existing idle expiry body
}
```

and:

```swift
case .idle, .waitingInput:
    // existing startup migration idle body
```

- [ ] **Step 7: Run focused and full SessionStore tests; verify GREEN**

Run:

```bash
swift test --filter SessionStoreIdleTests
swift test --filter SessionStoreSubagentTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 8: Review checkpoint**

Inspect only the Task 1 diff and confirm no event other than `idle_prompt` creates `.waitingInput`. Do not commit unless explicitly requested.

---

### Task 2: Add typed waiting toast and Session Switcher presentation

**Files:**
- Modify: `Sources/Stores/SessionFinishedStore.swift`
- Modify: `Sources/Stores/AppStore.swift:158-173`
- Modify: `Sources/Views/Overlay/SessionFinishedToast.swift`
- Modify: `Sources/Views/Overlay/SessionSwitcherView.swift:167-181`
- Modify: `Sources/Views/Overlay/OverlayManager.swift:341-355`
- Modify: `Sources/Resources/en.lproj/Localizable.strings:124-126`
- Modify: `Sources/Resources/zh.lproj/Localizable.strings:124-126`
- Create: `Tests/SessionFinishedStoreTests.swift`
- Modify: `Tests/SessionSwitcherTitleTests.swift`

**Interfaces:**
- Consumes: `AgentSession.Phase.waitingInput` from Task 1.
- Produces: `SessionFinishedStore.Toast.Kind`, `SessionFinishedStore.show(kind:sessionId:projectName:)`, `sessionPhaseLabel(_:)`.

- [ ] **Step 1: Write failing typed-toast tests**

Create `Tests/SessionFinishedStoreTests.swift`:

```swift
import XCTest
@testable import PeachyPet

@MainActor
final class SessionFinishedStoreTests: XCTestCase {
    func testWaitingToastUsesConfiguredCompletionDuration() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SessionFinishedStore.durationKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: SessionFinishedStore.durationKey)
            } else {
                defaults.removeObject(forKey: SessionFinishedStore.durationKey)
            }
        }
        defaults.set(12.0, forKey: SessionFinishedStore.durationKey)
        let store = SessionFinishedStore()

        store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")

        XCTAssertEqual(store.current?.kind, .waitingInput)
        XCTAssertEqual(store.current?.duration, 12.0)
        store.dismiss()
    }

    func testNewToastReplacesCurrentToast() {
        let store = SessionFinishedStore()
        store.show(kind: .completed, sessionId: "sid", projectName: "openclaw360")

        store.show(kind: .waitingInput, sessionId: "sid", projectName: "openclaw360")

        XCTAssertEqual(store.current?.kind, .waitingInput)
        store.dismiss()
    }
}
```

- [ ] **Step 2: Write the failing Session Switcher label test**

Add to `Tests/SessionSwitcherTitleTests.swift`:

```swift
func testWaitingInputPhaseLabelUsesLocalization() {
    XCTAssertEqual(
        sessionPhaseLabel(.waitingInput),
        t("switcher.waiting_for_input")
    )
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
swift test --filter SessionFinishedStoreTests
swift test --filter SessionSwitcherTitleTests/testWaitingInputPhaseLabel
```

Expected: compilation failure because the toast kind, new show signature, and `sessionPhaseLabel` do not exist.

- [ ] **Step 4: Add typed toast state**

In `SessionFinishedStore.swift`:

```swift
enum Kind: Equatable {
    case completed
    case waitingInput
}

struct Toast {
    let kind: Kind
    let sessionId: String
    let projectName: String
    let duration: TimeInterval
}

func show(kind: Kind, sessionId: String, projectName: String) {
    guard isEnabled else { return }
    let duration = toastDuration
    current = Toast(
        kind: kind,
        sessionId: sessionId,
        projectName: projectName,
        duration: duration
    )
    dismissTimer?.invalidate()
    dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
        DispatchQueue.main.async { self?.dismiss() }
    }
}
```

- [ ] **Step 5: Map events to toast kinds in AppStore**

Replace the Stop call with:

```swift
self.sessionFinishedStore.show(
    kind: .completed,
    sessionId: event.sessionId ?? "",
    projectName: event.projectName ?? "Project"
)
```

After the Stop block, add:

```swift
if event.eventType == .notification,
   event.notificationType == "idle_prompt" {
    self.sessionFinishedStore.show(
        kind: .waitingInput,
        sessionId: event.sessionId ?? "",
        projectName: event.projectName ?? "Project"
    )
    self.syncActiveCard()
    self.onToastChanged?()
}
```

Keep the existing `UserPromptSubmit` dismissal unchanged.

- [ ] **Step 6: Render toast copy and icon by kind**

In `SessionFinishedToast.swift`, derive:

```swift
private func iconName(for kind: SessionFinishedStore.Kind) -> String {
    switch kind {
    case .completed: return "checkmark.circle.fill"
    case .waitingInput: return "bubble.left.fill"
    }
}

private func messageKey(for kind: SessionFinishedStore.Kind) -> String {
    switch kind {
    case .completed: return "toast.task_completed"
    case .waitingInput: return "toast.waiting_for_input"
    }
}
```

Use them in the existing card:

```swift
Image(systemName: iconName(for: toast.kind))
// ...
Text(t(messageKey(for: toast.kind)))
```

- [ ] **Step 7: Add Session Switcher waiting presentation**

Expose a testable label helper near the existing project-label helper:

```swift
func sessionPhaseLabel(_ phase: AgentSession.Phase) -> String {
    switch phase {
    case .running: return "Running"
    case .waitingInput: return t("switcher.waiting_for_input")
    case .idle: return "Idle"
    case .compacting: return "Compacting"
    }
}
```

Use it from the row:

```swift
private var phaseLabel: String {
    sessionPhaseLabel(session.phase)
}
```

Add the orange phase color:

```swift
case .waitingInput: return Constants.orangePrimary
```

- [ ] **Step 8: Keep waiting sessions on mascot Idle animation**

In `OverlayManager.refreshInputs()`:

```swift
let isIdle = active.allSatisfy {
    $0.phase == .idle || $0.phase == .waitingInput
} || active.isEmpty
```

Do not add a new state-machine input.

- [ ] **Step 9: Add localized strings**

English:

```text
"toast.waiting_for_input" = "Waiting for your input";
"switcher.waiting_for_input" = "Waiting for input";
```

Chinese:

```text
"toast.waiting_for_input" = "等待你的回复";
"switcher.waiting_for_input" = "等待输入";
```

Both keys are consumed immediately: `SessionFinishedToast` uses `toast.waiting_for_input`, and `sessionPhaseLabel(.waitingInput)` uses `switcher.waiting_for_input`.

- [ ] **Step 10: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter SessionFinishedStoreTests
swift test --filter SessionSwitcherTitleTests
swift test --filter SessionStoreIdleTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 11: Review checkpoint**

Confirm `idle_prompt` replaces the currently visible toast, but its timer dismissal does not change `AgentSession.phase`. Do not commit unless explicitly requested.

---

### Task 3: Document, regress, and verify the real event flow

**Files:**
- Modify: `CLAUDE.md:171-183`
- Verify: all modified files

**Interfaces:**
- Consumes: Task 1 and Task 2 behavior.
- Produces: documented `Stop → idle → idle_prompt → waitingInput → UserPromptSubmit → running` lifecycle and runtime evidence.

- [ ] **Step 1: Update the project event lifecycle documentation**

Add to `CLAUDE.md`:

```markdown
- **等待输入**：`Stop` 先进入 idle；若 Claude Code 约 60 秒未收到回复并发送 `Notification(idle_prompt)`，session 转为 `waitingInput`，悬浮窗显示限时等待卡。下一次 `UserPromptSubmit` 恢复 running。
```

Update the phase descriptions so `.waitingInput` is listed separately from `.idle`.

- [ ] **Step 2: Run formatting and full test verification**

Run:

```bash
git diff --check
swift build
swift test
```

Expected:

- `git diff --check`: no output, exit 0.
- `swift build`: exit 0; pre-existing warnings may remain.
- `swift test`: all tests pass, zero failures.

- [ ] **Step 3: Replace the installed app while keeping one instance**

Run:

```bash
bash scripts/build-app.sh dist
pkill -x PeachyPet 2>/dev/null
sleep 1
rm -rf /Applications/PeachyPet.app
cp -R dist/PeachyPet.app /Applications/PeachyPet.app
open /Applications/PeachyPet.app
```

Confirm:

```bash
ps -axo pid=,command= | grep -E '[P]eachyPet'
curl -sS --max-time 2 http://127.0.0.1:45832/health
```

Expected: exactly one `/Applications/PeachyPet.app/Contents/MacOS/PeachyPet` process and `ok` health response.

- [ ] **Step 4: Drive the real `/hook` surface**

Use a unique test SID and send:

```json
{"hook_event_name":"UserPromptSubmit","session_id":"<sid>","cwd":"/tmp/peachy-waiting-check","source":"claude","prompt":"runtime check"}
{"hook_event_name":"Stop","session_id":"<sid>","cwd":"/tmp/peachy-waiting-check","source":"claude","last_assistant_message":"Please choose an option."}
{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"<sid>","cwd":"/tmp/peachy-waiting-check","source":"claude","message":"Claude is waiting for your input"}
```

Verify in `sessions.json`:

```text
phase = waitingInput
status = active
```

Verify the floating card displays `Waiting for your input`, then auto-dismisses after the configured completion duration while the Session Switcher remains orange `Waiting for input`.

Send the next prompt:

```json
{"hook_event_name":"UserPromptSubmit","session_id":"<sid>","cwd":"/tmp/peachy-waiting-check","source":"claude","prompt":"continue"}
```

Verify:

```text
phase = running
idleUntil = null
```

- [ ] **Step 5: Clean runtime probe data and restore the single app instance**

Stop PeachyPet, remove only the unique test SID from `sessions.json`, `events.json`, and `notifications.json` using an atomic Python rewrite, then reopen `/Applications/PeachyPet.app`.

Expected: the test SID has zero matches, exactly one PeachyPet process remains, and `/health` returns `ok`.

- [ ] **Step 6: Final diff review**

Run:

```bash
git status --short
git diff --stat
git diff --check
```

Confirm only the waiting-input implementation, its tests, approved spec/plan, prior uncommitted Codex startup fix, and the existing untracked `.codex/` directory are present. Do not stage `.codex/`, binaries, `dist/`, or app bundles.
