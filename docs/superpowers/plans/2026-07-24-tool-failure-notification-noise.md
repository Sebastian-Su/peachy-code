# Tool Failure Notification Noise Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop creating PeachyPet/macOS notifications for individual `PostToolUseFailure` events while preserving the failure in Activity Feed and keeping all other notification types unchanged.

**Architecture:** Keep `EventProcessor` as the single event-routing boundary. `PostToolUseFailure` remains a normal session activity so `EventStore.append(event)` and `SessionStore.recordEvent(event)` still run, but `createNotification(from:)` returns `nil` for that event type, preventing both `NotificationStore` persistence and `NotificationService.show`. No hook, parser, UI, or notification permission changes are needed.

**Tech Stack:** Swift 5.9+, SwiftUI/Observation, XCTest, Swift Package Manager.

## Global Constraints

- Preserve `PostToolUseFailure` in EventStore and SessionStore.
- Do not change hook registration or event decoding.
- Do not change NotificationService or macOS notification permissions.
- Do not add a settings toggle, retry threshold, debounce, or new notification category.
- Preserve existing notifications for permission requests, task completion, session lifecycle, and assistant messages.
- Do not include unrelated working-tree changes in the implementation commit.

---

### Task 1: Suppress Tool Failure Notification Creation

**Files:**
- Modify: `Sources/Services/EventProcessor.swift:95-205`
- Test: `Tests/EventProcessorTests.swift`

**Interfaces:**
- Consumes: Existing `EventProcessor.process(_:)`, `disposition(for:)`, `createNotification(from:)`, `EventStore`, `SessionStore`, `NotificationStore`, and `NotificationService`.
- Produces: `createNotification(from:)` returns `nil` for `.postToolUseFailure`; `process(_:)` still appends and records the event through the existing `.sessionActivity` path.

- [ ] **Step 1: Confirm the existing EventProcessor test setup**

`Tests/EventProcessorTests.swift` builds a processor from real `EventStore`, `SessionStore`, `NotificationStore`, and `NotificationService.shared` (no spy). Reuse that exact pattern. `NotificationService.show` only runs when `createNotification(from:)` returns a non-nil value and the category is not `.permissionRequest`, so asserting on `NotificationStore` is the reliable signal for a suppressed `.toolFailed` notification.

- [ ] **Step 2: Write the failing regression test**

Append this test to `Tests/EventProcessorTests.swift` (inside the `EventProcessorTests` class):

```swift
    func testPostToolUseFailureIsRecordedWithoutNotification() async throws {
        let eventStore = EventStore()
        eventStore.clear()
        let sessionStore = SessionStore()
        defer { sessionStore.stopTimers() }
        let notificationStore = NotificationStore()
        let processor = EventProcessor(
            eventStore: eventStore,
            sessionStore: sessionStore,
            notificationStore: notificationStore,
            notificationService: .shared
        )

        let sessionId = "event-processor-tool-failure-\(UUID().uuidString)"
        let event = AgentEvent(
            hookEventName: HookEventType.postToolUseFailure.rawValue,
            sessionId: sessionId,
            cwd: "/Users/test/openclaw360",
            toolName: "Bash",
            source: "claude"
        )

        await processor.process(event)

        // 失败事件仍进入 Activity Feed（EventStore）。
        XCTAssertTrue(eventStore.events.contains(where: { $0.sessionId == sessionId }),
                      "PostToolUseFailure 应写入 EventStore")
        // 但不再生成 Tool Failed 通知。
        XCTAssertNil(notificationStore.notifications.first(where: { $0.sessionId == sessionId }),
                     "PostToolUseFailure 不应进入 notificationStore")
    }
```


- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
swift test --filter EventProcessorTests/testPostToolUseFailureIsRecordedWithoutNotification
```

Expected: FAIL because the current `createNotification(from:)` returns an `AppNotification` with title `Tool Failed`.

- [ ] **Step 4: Implement the minimal production change**

In `Sources/Services/EventProcessor.swift`, remove the `.postToolUseFailure` branch that constructs `AppNotification`:

```swift
        case .postToolUseFailure:
            return nil
```

Keep the `.postToolUseFailure` event inside the existing default `.sessionActivity` disposition. Do not remove the hook event or alter `eventStore.append(event)` / `sessionStore.recordEvent(event)`.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter EventProcessorTests/testPostToolUseFailureIsRecordedWithoutNotification
```

Expected: PASS. The event remains in EventStore, while NotificationStore and the notification service remain unchanged.

- [ ] **Step 6: Run related EventProcessor tests**

Run:

```bash
swift test --filter EventProcessorTests
```

Expected: PASS, including existing permission, stop, session lifecycle, and event disposition tests.

- [ ] **Step 7: Commit only this implementation and its regression test**

Before staging, verify unrelated existing changes remain unstaged:

```bash
git status --short
git diff --check
```

Stage only `Sources/Services/EventProcessor.swift` and `Tests/EventProcessorTests.swift`, then commit with the repository’s Chinese commit convention:

```bash
git add "Sources/Services/EventProcessor.swift" "Tests/EventProcessorTests.swift"
git commit -m "$(cat <<'EOF'
fix: 关闭工具失败系统通知
EOF
)"
```

Do not stage `.codex/`, the existing Escape/session changes, or any other unrelated file.

---

### Task 2: Full Verification

**Files:**
- Read-only verification of `Sources/Services/EventProcessor.swift` and `Tests/EventProcessorTests.swift`.
- No additional production files should change.

**Interfaces:**
- Consumes: Task 1’s committed `EventProcessor` behavior and regression test.
- Produces: Evidence that failure events remain recorded, failure notifications are suppressed, and all unrelated behavior passes.

- [ ] **Step 1: Run the complete Swift test suite**

Run:

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build the package**

Run:

```bash
swift build
```

Expected: build completes successfully.

- [ ] **Step 3: Check the final diff scope**

Run:

```bash
git status --short
git diff HEAD^ --check
git show --stat --oneline HEAD
```

Expected: the new commit contains only the EventProcessor change and its regression test; pre-existing unrelated modifications remain outside the commit.

- [ ] **Step 4: Report the observable behavior**

Confirm in the final report:

- `PostToolUseFailure` remains visible in Activity Feed.
- No `Tool Failed` item is added to the notification center.
- No macOS system notification is emitted for that event.
- Permission, completion, lifecycle, and assistant-message notifications remain unchanged.
