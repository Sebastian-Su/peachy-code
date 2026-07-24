import XCTest
@testable import PeachyPet

final class SessionStoreMetadataTests: XCTestCase {
    func testAgentSessionDisplayUsesProjectOverrideThenProjectName() {
        let overridden = makeSession(
            projectName: "masko-code",
            projectDisplayName: "namiwork-core"
        )
        let fallback = makeSession(projectName: "masko-code")

        XCTAssertEqual(overridden.displayProjectName, "namiwork-core")
        XCTAssertEqual(fallback.displayProjectName, "masko-code")
    }

    func testAgentSessionDisplayUsesTitleThenFirstPrompt() {
        let titled = makeSession(
            sessionTitle: "解决 release 分支冲突",
            firstUserPrompt: "检查 release 分支"
        )
        let fallback = makeSession(firstUserPrompt: "解决 release 分支冲突")

        XCTAssertEqual(titled.displaySessionTitle, "解决 release 分支冲突")
        XCTAssertEqual(fallback.displaySessionTitle, "解决 release 分支冲突")
    }

    func testAgentSessionDisplayOmitsEmptyTitleSeparator() {
        let session = makeSession(sessionTitle: " \n ", firstUserPrompt: "\t")

        XCTAssertNil(session.displaySessionTitle)
    }

    // MARK: - Bug 1: whitespace sessionTitle must not suppress a valid firstUserPrompt

    func testWhitespaceTitleFallsBackToFirstPrompt() {
        let session = makeSession(sessionTitle: "  \n  ", firstUserPrompt: "解决 release 分支冲突")

        XCTAssertEqual(session.displaySessionTitle, "解决 release 分支冲突")
    }

    // MARK: - Bug 2: empty/whitespace project name strings must fall through to "Session"

    func testEmptyProjectNameFallsThrough() {
        let session = makeSession(projectDir: nil, projectName: "")

        XCTAssertEqual(session.displayProjectName, "Session")
    }

    func testRootProjectDirFallsThrough() {
        let session = AgentSession(
            id: "session-root",
            projectDir: "/",
            projectName: nil,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        )

        XCTAssertEqual(session.displayProjectName, "Session")
    }

    func testFirstUserPromptIsStoredOnlyOnce() {
        let store = SessionStore(idleRetentionDuration: 300)
        let sessionId = "prompt-\(UUID().uuidString)"

        store.recordEvent(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            prompt: "  First prompt  "
        ))
        store.recordEvent(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            prompt: "Second prompt"
        ))

        XCTAssertEqual(
            store.sessions.first(where: { $0.id == sessionId })?.firstUserPrompt,
            "  First prompt  "
        )
        store.stopTimers()
    }

    func testMetadataUpdateChangesOnlyMetadataFields() {
        let store = SessionStore(idleRetentionDuration: 300)
        let session = AgentSession(
            id: "metadata-\(UUID().uuidString)",
            projectDir: "/tmp/original",
            projectName: "original",
            status: .active,
            phase: .running,
            eventCount: 7,
            startedAt: Date(timeIntervalSince1970: 100),
            lastEventAt: Date(timeIntervalSince1970: 200),
            lastToolName: "Bash",
            activeSubagentCount: 2,
            terminalPid: 123,
            shellPid: 456,
            transcriptPath: "/tmp/transcript.jsonl"
        )
        store.injectSessionForTesting(session)
        let orderBefore = store.sessions.map(\.id)
        var notificationCount = 0
        store.onPhasesChanged = { notificationCount += 1 }

        let update = SessionMetadataUpdate(
            sessionId: session.id,
            sessionTitle: "New title",
            firstUserPrompt: "First prompt",
            projectDisplayName: "New project"
        )
        store.updateMetadata(update)
        store.updateMetadata(update)
        store.updateMetadata(SessionMetadataUpdate(
            sessionId: session.id,
            sessionTitle: "  ",
            firstUserPrompt: "Replacement prompt",
            projectDisplayName: nil
        ))

        let updated = try! XCTUnwrap(store.sessions.first(where: { $0.id == session.id }))
        XCTAssertEqual(updated.sessionTitle, "New title")
        XCTAssertEqual(updated.firstUserPrompt, "First prompt")
        XCTAssertEqual(updated.projectDisplayName, "New project")
        XCTAssertEqual(updated.phase, session.phase)
        XCTAssertEqual(updated.status, session.status)
        XCTAssertEqual(updated.lastEventAt, session.lastEventAt)
        XCTAssertEqual(updated.eventCount, session.eventCount)
        XCTAssertEqual(updated.activeSubagentCount, session.activeSubagentCount)
        XCTAssertEqual(store.sessions.map(\.id), orderBefore)
        XCTAssertEqual(notificationCount, 1)
        store.stopTimers()
    }

    func testMetadataUpdatePersistsAndReloads() {
        let sessionId = "persist-\(UUID().uuidString)"
        let store = SessionStore(idleRetentionDuration: 300)
        store.injectSessionForTesting(AgentSession(
            id: sessionId,
            projectDir: "/tmp/project",
            projectName: "project",
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        ))

        store.updateMetadata(SessionMetadataUpdate(
            sessionId: sessionId,
            sessionTitle: "Persisted title",
            firstUserPrompt: "Persisted prompt",
            projectDisplayName: "Persisted project"
        ))
        store.stopTimers()

        let reloadedStore = SessionStore(idleRetentionDuration: 300)
        let reloaded = try! XCTUnwrap(reloadedStore.sessions.first(where: { $0.id == sessionId }))
        XCTAssertEqual(reloaded.sessionTitle, "Persisted title")
        XCTAssertEqual(reloaded.firstUserPrompt, "Persisted prompt")
        XCTAssertEqual(reloaded.projectDisplayName, "Persisted project")
        reloadedStore.stopTimers()
    }

    func testMetadataForUnknownSessionIsIgnored() {
        let store = SessionStore(idleRetentionDuration: 300)
        let sessionsBefore = store.sessions.map(\.id)
        var notificationCount = 0
        store.onPhasesChanged = { notificationCount += 1 }

        store.updateMetadata(SessionMetadataUpdate(
            sessionId: "unknown-\(UUID().uuidString)",
            sessionTitle: "Ignored title",
            firstUserPrompt: "Ignored prompt",
            projectDisplayName: "Ignored project"
        ))

        XCTAssertEqual(store.sessions.map(\.id), sessionsBefore)
        XCTAssertEqual(notificationCount, 0)
        store.stopTimers()
    }

    func testInternalTurnRollbackRestoresFirstUserPrompt() {
        let store = SessionStore(idleRetentionDuration: 300)
        let sessionId = "rollback-\(UUID().uuidString)"
        let taskId = "task-\(UUID().uuidString)"
        store.injectSessionForTesting(AgentSession(
            id: sessionId,
            projectDir: "/tmp/project",
            projectName: "project",
            status: .active,
            phase: .running,
            eventCount: 3,
            startedAt: Date(),
            lastEventAt: Date(),
            terminalPid: 123
        ))

        store.saveSnapshot(taskId: taskId, sessionId: sessionId)
        store.recordEvent(AgentEvent(
            hookEventName: HookEventType.userPromptSubmit.rawValue,
            sessionId: sessionId,
            prompt: "Internal approval prompt"
        ))
        store.rollbackInternalTurn(taskId: taskId, sessionId: sessionId)

        XCTAssertNil(store.sessions.first(where: { $0.id == sessionId })?.firstUserPrompt)
        store.stopTimers()
    }

    private func makeSession(
        projectDir: String? = "/tmp/masko-code",
        projectName: String? = "masko-code",
        sessionTitle: String? = nil,
        projectDisplayName: String? = nil,
        firstUserPrompt: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: "session-1",
            projectDir: projectDir,
            projectName: projectName,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date(),
            sessionTitle: sessionTitle,
            projectDisplayName: projectDisplayName,
            firstUserPrompt: firstUserPrompt
        )
    }
}
