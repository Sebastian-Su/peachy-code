import Foundation
import XCTest
@testable import PeachyPet

final class PendingPermissionStoreTests: XCTestCase {
    func testTopVisiblePermissionUsesNewestNonCollapsedPermission() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        store.add(event: makeCodexPermissionEvent(toolUseId: "older", cmd: "git status"), transport: MockTransport())
        let fallback = MockTransport()
        fallback.capabilities = [.openTerminal]
        store.add(event: makeCodexPermissionEvent(toolUseId: "newer", cmd: "git push"), transport: fallback)

        let top = try XCTUnwrap(store.topVisiblePermission)
        XCTAssertEqual(top.event.toolUseId, "newer")
        XCTAssertTrue(top.isTerminalFallback)
    }

    func testCollapseRefreshesTopVisiblePermissionState() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }
        var changeCount = 0
        store.onPendingCountChange = { changeCount += 1 }

        store.add(event: makeCodexPermissionEvent(toolUseId: "older", cmd: "git status"), transport: MockTransport())
        let fallback = MockTransport()
        fallback.capabilities = [.openTerminal]
        store.add(event: makeCodexPermissionEvent(toolUseId: "newer", cmd: "git push"), transport: fallback)
        let fallbackId = try XCTUnwrap(store.topVisiblePermission?.id)
        let countBeforeCollapse = changeCount

        store.collapse(id: fallbackId)

        XCTAssertGreaterThan(changeCount, countBeforeCollapse)
        XCTAssertEqual(store.topVisiblePermission?.event.toolUseId, "older")
        XCTAssertFalse(try XCTUnwrap(store.topVisiblePermission).isTerminalFallback)
    }

    func testStaleEscapeRevisionDoesNotDismissNewFallback() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }
        let first = MockTransport()
        first.capabilities = [.openTerminal]
        store.add(
            event: makeCodexPermissionEvent(toolUseId: "first", cmd: "git status"),
            transport: first
        )
        let staleRevision = store.visibilityRevision
        let firstId = try XCTUnwrap(store.topVisiblePermission?.id)
        store.dismissLocally(id: firstId)

        let second = MockTransport()
        second.capabilities = [.openTerminal]
        store.add(
            event: makeCodexPermissionEvent(toolUseId: "second", cmd: "git log"),
            transport: second
        )

        store.dismissTopTerminalFallback(expectedRevision: staleRevision)

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.topVisiblePermission?.event.toolUseId, "second")
    }

    func testDismissTopTerminalFallbackDoesNotDenyActionablePermission() {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }
        let actionable = MockTransport()
        store.add(
            event: makeCodexPermissionEvent(toolUseId: "actionable", cmd: "git push"),
            transport: actionable
        )

        store.dismissTopTerminalFallback(expectedRevision: store.visibilityRevision)

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertTrue(actionable.decisions.isEmpty)
    }

    func testDismissFallbackOrDenyRemovesFallbackWithoutSendingDecision() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let transport = MockTransport()
        transport.capabilities = [.openTerminal]
        store.add(event: makeCodexPermissionEvent(toolUseId: "call_local", cmd: "git status"), transport: transport)
        let id = try XCTUnwrap(store.pending.first?.id)

        store.dismissFallbackOrDeny(id: id)

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(transport.decisions.isEmpty)
    }

    func testDismissFallbackOrDenySendsDenyForActionablePermission() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let transport = MockTransport()
        store.add(event: makeCodexPermissionEvent(toolUseId: "call_deny", cmd: "git push"), transport: transport)
        let id = try XCTUnwrap(store.pending.first?.id)

        store.dismissFallbackOrDeny(id: id)

        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(transport.decisions, [.deny])
    }

    func testResolveAllowSendsDecision() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let transport = MockTransport()
        let event = makeCodexPermissionEvent(toolUseId: "call_1", cmd: "git push")
        store.add(event: event, transport: transport)

        let id = try XCTUnwrap(store.pending.first?.id)
        store.resolve(id: id, decision: .allow)

        XCTAssertEqual(transport.decisions, [.allow])
        XCTAssertEqual(store.pending.count, 0)
    }

    func testAddSkipsDuplicateToolUseId() {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let first = makeCodexPermissionEvent(toolUseId: "call_dup", cmd: "git push")
        let second = makeCodexPermissionEvent(toolUseId: "call_dup", cmd: "git pull")

        store.add(event: first, transport: MockTransport())
        store.add(event: second, transport: MockTransport())

        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(store.pending.first?.event.toolInput?["cmd"]?.stringValue, "git push")
    }

    func testResolveWithAnswersSendsUpdatedInput() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let transport = MockTransport()
        let event = makeCodexPermissionEvent(toolUseId: "call_3", cmd: "scripts/codex-mascot-smoke.sh")
        store.add(event: event, transport: transport)
        let id = try XCTUnwrap(store.pending.first?.id)

        store.resolveWithAnswers(id: id, answers: ["q1": "yes"])

        let sent = try XCTUnwrap(transport.updatedInputs.first)
        let answers = sent["answers"] as? [String: String]
        XCTAssertEqual(answers?["q1"], "yes")
        XCTAssertEqual(store.pending.count, 0)
    }

    func testResolveWithFeedbackSendsUpdatedInput() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let transport = MockTransport()
        let event = makeCodexPermissionEvent(toolUseId: "call_4", cmd: "update plan")
        store.add(event: event, transport: transport)
        let id = try XCTUnwrap(store.pending.first?.id)

        store.resolveWithFeedback(id: id, feedback: "Please trim this down.")

        let sent = try XCTUnwrap(transport.updatedInputs.first)
        XCTAssertEqual(sent["userFeedback"] as? String, "Please trim this down.")
        XCTAssertEqual(store.pending.count, 0)
    }

    func testResolveWithPermissionsSendsUpdatedPermissions() throws {
        let store = PendingPermissionStore()
        defer { store.stopTimers() }

        let transport = MockTransport()
        let event = makeCodexPermissionEvent(toolUseId: "call_5", cmd: "git push")
        store.add(event: event, transport: transport)
        let id = try XCTUnwrap(store.pending.first?.id)

        let suggestions = [
            PermissionSuggestion(type: "setMode", destination: "session", behavior: nil, rules: nil, mode: "acceptEdits"),
        ]
        store.resolveWithPermissions(id: id, suggestions: suggestions)

        let sent = try XCTUnwrap(transport.updatedPermissions.first)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["type"] as? String, "setMode")
        XCTAssertEqual(store.pending.count, 0)
    }

    func testToolInputPreviewPrefersCodexCmdField() {
        let permission = PendingPermission(
            id: UUID(),
            event: makeCodexPermissionEvent(toolUseId: "call_preview", cmd: "git push origin feat/codex-support"),
            transport: MockTransport(),
            receivedAt: Date(),
            resolvedToolUseId: "call_preview"
        )

        XCTAssertEqual(permission.toolInputPreview, "git push origin feat/codex-support")
    }

    func testFullToolInputTextPrefersCodexCmdField() {
        let permission = PendingPermission(
            id: UUID(),
            event: makeCodexPermissionEvent(toolUseId: "call_full", cmd: "scripts/codex-mascot-smoke.sh"),
            transport: MockTransport(),
            receivedAt: Date(),
            resolvedToolUseId: "call_full"
        )

        XCTAssertEqual(permission.fullToolInputText, "scripts/codex-mascot-smoke.sh")
    }

    func testAskUserQuestionPreviewSupportsGenericQuestionArrayPayload() {
        let permission = PendingPermission(
            id: UUID(),
            event: AgentEvent(
                hookEventName: HookEventType.permissionRequest.rawValue,
                sessionId: "session-question-preview",
                cwd: "/tmp/project",
                toolName: "AskUserQuestion",
                toolInput: [
                    "questions": AnyCodable([
                        [
                            "id": "remote",
                            "question": "Which remote should we use?",
                        ],
                    ]),
                ],
                toolUseId: "call_question_preview",
                source: "codex-cli"
            ),
            transport: MockTransport(),
            receivedAt: Date(),
            resolvedToolUseId: "call_question_preview"
        )

        XCTAssertEqual(permission.toolInputPreview, "Which remote should we use?")
    }

    func testAskUserQuestionFullTextSupportsGenericQuestionArrayPayload() {
        let permission = PendingPermission(
            id: UUID(),
            event: AgentEvent(
                hookEventName: HookEventType.permissionRequest.rawValue,
                sessionId: "session-question-full",
                cwd: "/tmp/project",
                toolName: "AskUserQuestion",
                toolInput: [
                    "questions": AnyCodable([
                        [
                            "id": "remote",
                            "question": "Which remote should we use?",
                        ],
                        [
                            "id": "approval",
                            "question": "Should this be always allowed?",
                        ],
                    ]),
                ],
                toolUseId: "call_question_full",
                source: "codex-cli"
            ),
            transport: MockTransport(),
            receivedAt: Date(),
            resolvedToolUseId: "call_question_full"
        )

        XCTAssertEqual(
            permission.fullToolInputText,
            "Which remote should we use?\n\nShould this be always allowed?"
        )
    }

    private func makeCodexPermissionEvent(toolUseId: String, cmd: String) -> AgentEvent {
        AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "session-test",
            cwd: "/tmp/project",
            toolName: "exec_command",
            toolInput: [
                "cmd": AnyCodable(cmd),
                "sandbox_permissions": AnyCodable("require_escalated"),
            ],
            toolUseId: toolUseId,
            source: "codex-cli"
        )
    }
}

private final class MockTransport: ResponseTransport {
    var capabilities: Set<ResponseCapability> = [.permissionResponse, .updatedInput, .updatedPermissions]
    var isAlive: Bool = true

    var decisions: [PermissionDecision] = []
    var updatedInputs: [[String: Any]] = []
    var updatedPermissions: [[[String: Any]]] = []
    private var remoteCloseHandler: (() -> Void)?

    func sendDecision(_ decision: PermissionDecision) {
        decisions.append(decision)
    }

    func sendAllowWithUpdatedInput(_ updatedInput: [String: Any]) {
        updatedInputs.append(updatedInput)
    }

    func sendAllowWithUpdatedPermissions(_ permissions: [[String: Any]]) {
        updatedPermissions.append(permissions)
    }

    func cancel() {
        isAlive = false
        remoteCloseHandler?()
    }

    func onRemoteClose(_ handler: @escaping () -> Void) {
        remoteCloseHandler = handler
    }
}
