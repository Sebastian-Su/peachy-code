import XCTest
@testable import PeachyPet

@MainActor
final class EventProcessorDispositionTests: XCTestCase {
    private func makeProcessor() -> (EventProcessor, NotificationStore, SessionStore) {
        let es = EventStore(); es.clear()
        let ss = SessionStore()
        let ns = NotificationStore()
        let proc = EventProcessor(
            eventStore: es,
            sessionStore: ss,
            notificationStore: ns,
            notificationService: .shared
        )
        return (proc, ns, ss)
    }

    // internalResult → no session created, no notification
    func testInternalResultDoesNotCreateSession() async {
        let (proc, ns, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "disp-internal-\(UUID().uuidString)"
        let event = AgentEvent(
            hookEventName: HookEventType.internalResult.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            source: "codex-cli",
            taskId: "t-internal"
        )
        await proc.process(event)
        XCTAssertNil(ss.sessions.first(where: { $0.id == sessionId }),
                     "internalResult must not create a Session")
        XCTAssertNil(ns.notifications.first(where: { $0.sessionId == sessionId }),
                     "internalResult must not produce a notification")
    }

    // internalResult → event IS recorded in EventStore
    func testInternalResultIsRecordedInEventStore() async {
        let es = EventStore(); es.clear()
        let ss = SessionStore()
        defer { ss.stopTimers() }
        let ns = NotificationStore()
        let proc = EventProcessor(
            eventStore: es,
            sessionStore: ss,
            notificationStore: ns,
            notificationService: .shared
        )
        let sessionId = "disp-internal-feed-\(UUID().uuidString)"
        let event = AgentEvent(
            hookEventName: HookEventType.internalResult.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            source: "codex-cli",
            taskId: "t-feed"
        )
        await proc.process(event)
        XCTAssertTrue(es.events.contains(where: { $0.hookEventName == "InternalResult" }),
                      "internalResult must appear in EventStore activity feed")
    }

    // taskCompleted → no notification generated
    func testTaskCompletedDoesNotGenerateNotification() async {
        let (proc, ns, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "disp-taskcompleted-\(UUID().uuidString)"
        // First create the session via a stop event so taskCompleted has something to update
        let stopEvent = AgentEvent(
            hookEventName: HookEventType.stop.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            source: "codex-cli",
            reason: "completed"
        )
        await proc.process(stopEvent)
        let countBefore = ns.notifications.filter { $0.sessionId == sessionId }.count

        let event = AgentEvent(
            hookEventName: HookEventType.taskCompleted.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            source: "codex-cli",
            taskSubject: "step done"
        )
        await proc.process(event)
        let countAfter = ns.notifications.filter { $0.sessionId == sessionId }.count
        XCTAssertEqual(countBefore, countAfter,
                       "taskCompleted must not add new notification (Stop already notified)")
    }

    // stop → one notification generated with category .sessionLifecycle
    func testStopGeneratesExactlyOneNotification() async {
        let (proc, ns, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "disp-stop-\(UUID().uuidString)"
        let event = AgentEvent(
            hookEventName: HookEventType.stop.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            source: "codex-cli",
            reason: "completed",
            lastAssistantMessage: "All done"
        )
        await proc.process(event)
        let matches = ns.notifications.filter { $0.sessionId == sessionId }
        XCTAssertEqual(matches.count, 1, "Stop must generate exactly one notification")
        XCTAssertEqual(matches[0].category, .sessionLifecycle)
    }

    func testCodexDesktopPersonalizedSuggestionsDoNotCreateVisibleSession() async {
        let (proc, ns, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "019f9887-c16d-7420-b427-a9d19ce080e1"

        let startVisible = await proc.process(AgentEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            permissionMode: "bypassPermissions",
            source: "startup",
            model: "gpt-5.6-terra"
        ))
        let promptVisible = await proc.process(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            permissionMode: "bypassPermissions",
            prompt: "# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex",
            model: "gpt-5.6-terra"
        ))
        let stopVisible = await proc.process(AgentEvent(
            hookEventName: HookEventType.stop.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            reason: "completed"
        ))
        let endVisible = await proc.process(AgentEvent(
            hookEventName: HookEventType.sessionEnd.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project"
        ))

        XCTAssertFalse(startVisible)
        XCTAssertFalse(promptVisible)
        XCTAssertFalse(stopVisible)
        XCTAssertFalse(endVisible)
        XCTAssertNil(ss.sessions.first(where: { $0.id == sessionId }))
        XCTAssertNil(ns.notifications.first(where: { $0.sessionId == sessionId }))
    }

    // A real Codex Desktop session (source=vscode) must not be filtered.
    func testRealCodexDesktopSessionIsVisible() async {
        let (proc, _, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "019f9312-ee04-71c2-b020-0666c3c80334"

        await proc.process(AgentEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            source: "vscode"
        ))
        await proc.process(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            prompt: "Fix the login bug",
            source: "vscode"
        ))

        let session = ss.sessions.first(where: { $0.id == sessionId })
        XCTAssertEqual(session?.phase, .running)
        XCTAssertEqual(session?.firstUserPrompt, "Fix the login bug")
    }

    // A user genuinely typing "hyperpersonalized suggestions" in a terminal Codex
    // session (has terminal/transcript) must NOT be filtered.
    func testUserPromptWithTerminalIsNotFiltered() async {
        let (proc, _, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "019f9312-ee04-71c2-b020-0666c3c80335"

        await proc.process(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            prompt: "explain hyperpersonalized suggestions and what this user can do with Codex",
            source: "codex-cli",
            terminalPid: 4242
        ))

        XCTAssertNotNil(ss.sessions.first(where: { $0.id == sessionId }))
    }

    // A real Claude Code startup (UUIDv4, no preceding suppressed SessionStart)
    // whose prompt happens to contain the phrases must NOT be filtered.
    func testUUIDv4PromptWithSuggestionPhrasesIsNotFiltered() async {
        let (proc, _, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "1f0e5b4c-3a2d-4e6f-8a9b-0c1d2e3f4a5b" // UUIDv4

        let visible = await proc.process(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            permissionMode: "bypassPermissions",
            prompt: "show hyperpersonalized suggestions for what this user can do with Codex"
        ))

        XCTAssertTrue(visible)
        XCTAssertNotNil(ss.sessions.first(where: { $0.id == sessionId }))
    }

    // A real Claude Code SessionStart with UUIDv4 + source=startup must NOT be filtered.
    func testUUIDv4StartupIsNotFiltered() async {
        let (proc, _, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "1f0e5b4c-3a2d-4e6f-8a9b-0c1d2e3f4a5c" // UUIDv4

        let visible = await proc.process(AgentEvent(
            hookEventName: HookEventType.sessionStart.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            permissionMode: "bypassPermissions",
            source: "startup"
        ))

        XCTAssertTrue(visible)
        XCTAssertNotNil(ss.sessions.first(where: { $0.id == sessionId }))
    }

    // Existing permissionRequest not in NotificationStore (regression guard)
    func testPermissionRequestNotInNotificationStore() async {
        let (proc, ns, ss) = makeProcessor()
        defer { ss.stopTimers() }
        let sessionId = "disp-perm-\(UUID().uuidString)"
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: sessionId,
            cwd: "/tmp",
            toolName: "Bash",
            source: "claude"
        )
        await proc.process(event)
        XCTAssertNil(ns.notifications.first(where: { $0.sessionId == sessionId }),
                     "permissionRequest must not appear in NotificationStore")
    }
}
