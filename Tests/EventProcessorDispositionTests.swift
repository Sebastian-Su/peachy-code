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
