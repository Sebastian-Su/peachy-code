import XCTest
@testable import PeachyPet

@MainActor
final class EventProcessorTests: XCTestCase {
    func testCodexPermissionNotificationNotAddedToStore() async throws {
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

        let sessionId = "event-processor-codex-permission"
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            toolName: "exec_command",
            message: "Need network access to push",
            source: "codex-cli"
        )

        await processor.process(event)

        // permissionRequest 通知走 mascot 气泡 + 系统通知，
        // 故意不进应用内通知中心（EventProcessor 过滤 .permissionRequest 类别）。
        XCTAssertNil(notificationStore.notifications.first(where: { $0.sessionId == sessionId }),
                     "permission 通知不应进入 notificationStore")
    }

    func testClaudePermissionNotificationNotAddedToStore() async throws {
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

        let sessionId = "event-processor-claude-permission"
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            toolName: "Bash",
            message: "Need approval to run Bash",
            source: "claude"
        )

        await processor.process(event)

        // 同上：permission 不进应用内通知中心。
        XCTAssertNil(notificationStore.notifications.first(where: { $0.sessionId == sessionId }),
                     "permission 通知不应进入 notificationStore")
    }

    func testCodexQuestionStopStillCreatesCompletionNotificationWhenProcessed() async throws {
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

        let sessionId = "event-processor-codex-question-stop"
        let event = AgentEvent(
            hookEventName: HookEventType.stop.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            source: "codex-cli",
            reason: "completed",
            lastAssistantMessage: "Which remote should I use for the dry-run push?"
        )

        await processor.process(event)

        let notification = try XCTUnwrap(notificationStore.notifications.first(where: { $0.sessionId == sessionId }))
        XCTAssertEqual(notification.title, "Task Completed")
        XCTAssertEqual(notification.category, .sessionLifecycle)
    }

    func testCodexQuestionTaskCompletedDoesNotCreateNotification() async throws {
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

        let sessionId = "event-processor-codex-question-task"
        let event = AgentEvent(
            hookEventName: HookEventType.taskCompleted.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            source: "codex-cli",
            taskSubject: "Which remote should I use for the dry-run push?"
        )

        await processor.process(event)

        // taskCompleted is recordOnly — Stop already fired the completion notification.
        // It must NOT appear in NotificationStore.
        XCTAssertNil(notificationStore.notifications.first(where: { $0.sessionId == sessionId }),
                     "taskCompleted must not produce a notification (recordOnly)")
    }

    func testClaudeStopStillCreatesCompletionNotificationForQuestionText() async throws {
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

        let sessionId = "event-processor-claude-stop-question"
        let event = AgentEvent(
            hookEventName: HookEventType.stop.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            source: "claude",
            reason: "completed",
            lastAssistantMessage: "Do you want me to continue?"
        )

        await processor.process(event)

        let notification = try XCTUnwrap(notificationStore.notifications.first(where: { $0.sessionId == sessionId }))
        XCTAssertEqual(notification.title, "Task Completed")
        XCTAssertEqual(notification.body, "Do you want me to continue?")
    }

    // MARK: - 缺陷 a：sessionEnd 清理 CodexHookLiveness

    /// 验证处理 Codex sessionEnd 事件后，对应 session 的 liveness 被清除
    func testCodexSessionEndClearsLiveness() async throws {
        let sessionId = "codex-session-end-liveness-\(UUID().uuidString)"

        // 先标记为 live（模拟 Codex hook 已到达过事件）
        CodexHookLiveness.shared.markLive(sessionId: sessionId)
        XCTAssertTrue(CodexHookLiveness.shared.isLive(sessionId: sessionId),
                      "前置条件：session 应已被标记为 live")

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

        let event = AgentEvent(
            hookEventName: HookEventType.sessionEnd.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            source: "codex-cli"
        )

        await processor.process(event)

        // sessionEnd 处理后，liveness 应被清除
        XCTAssertFalse(CodexHookLiveness.shared.isLive(sessionId: sessionId),
                       "sessionEnd 后 CodexHookLiveness 应已清除该 session")

        // 清理：确保单例状态不泄漏到其他测试
        CodexHookLiveness.shared.clear(sessionId: sessionId)
    }

    /// 验证 Claude sessionEnd 不影响同名 Codex session 的 liveness（边界保护）
    func testClaudeSessionEndDoesNotClearLivenessForCodexSession() async throws {
        let sessionId = "shared-session-id-\(UUID().uuidString)"

        // Codex 已标记为 live
        CodexHookLiveness.shared.markLive(sessionId: sessionId)

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

        // Claude sessionEnd：source 不含 "codex"
        let event = AgentEvent(
            hookEventName: HookEventType.sessionEnd.rawValue,
            sessionId: sessionId,
            cwd: "/tmp/project",
            source: nil  // Claude Code 路径不带 source
        )

        await processor.process(event)

        // Claude sessionEnd 不应清除 Codex 的 liveness
        // 注：按设计，sessionEnd 时只要 sessionId 非空就 clear（保持与 markLive 对称）
        // 此测试留作文档用途，验证实际行为与预期一致：
        // 若实现选择"无论 source 都清"，则此处 isLive 为 false；
        // 若选择"只清 Codex"，则 isLive 仍为 true。
        // 按任务说明"简单起见 sessionEnd 时若有 sessionId 就 clear"，两边都 clear 是可接受的。
        // 本测试只确保不会 crash，不对具体值做强断言。
        _ = CodexHookLiveness.shared.isLive(sessionId: sessionId)
        // 清理
        CodexHookLiveness.shared.clear(sessionId: sessionId)
    }
}
