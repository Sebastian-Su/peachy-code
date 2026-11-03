import XCTest
@testable import PeachyPet

final class NotificationAgentTests: XCTestCase {
    func testNewNotificationRecordsItsAgent() async throws {
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

        let codexSession = "notification-agent-codex"
        await processor.process(AgentEvent(
            hookEventName: HookEventType.stop.rawValue, sessionId: codexSession, cwd: "/tmp/project",
            reason: "completed", lastAssistantMessage: "done", client: "codex-cli"
        ))
        let claudeSession = "notification-agent-claude"
        await processor.process(AgentEvent(
            hookEventName: HookEventType.stop.rawValue, sessionId: claudeSession, cwd: "/tmp/project",
            reason: "completed", lastAssistantMessage: "done"
        ))

        XCTAssertEqual(notificationStore.notifications.first { $0.sessionId == codexSession }?.agentSource, .codex)
        XCTAssertEqual(notificationStore.notifications.first { $0.sessionId == claudeSession }?.agentSource, .claudeCode)
    }

    /// Notifications saved before this field existed must still load (N1).
    func testNotificationSavedWithoutAgentStillDecodes() throws {
        let saved = AppNotification(title: "Old", body: "b", category: .taskCompleted, sessionId: "s")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([saved])) as? [[String: Any]])
        object[0].removeValue(forKey: "agentSource")
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode([AppNotification].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].title, "Old")
        XCTAssertNil(decoded[0].agentSource)
    }
}
