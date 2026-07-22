import XCTest
@testable import PeachyPet

final class PermissionTargetAppTests: XCTestCase {
    func testResolvesMatchedSessionFocusAppBundleId() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "session-1",
            cwd: "/tmp/project",
            terminalPid: 123
        )
        var session = AgentSession(
            id: "session-1",
            projectDir: "/tmp/project",
            projectName: "project",
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        )
        session.terminalBundleId = "com.mitchellh.ghostty"

        XCTAssertEqual(
            permissionTargetBundleId(event: event, sessions: [session]),
            "com.mitchellh.ghostty"
        )
    }

    func testFallsBackToEventTerminalPidWhenSessionIsMissing() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "missing-session",
            cwd: "/tmp/project",
            terminalPid: 42
        )

        let bundleId = permissionTargetBundleId(
            event: event,
            sessions: [],
            bundleIdForPid: { pid in
                XCTAssertEqual(pid, 42)
                return "com.mitchellh.ghostty"
            }
        )

        XCTAssertEqual(bundleId, "com.mitchellh.ghostty")
    }

    func testCodexDesktopSessionResolvesCodexApp() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "codex-desktop",
            cwd: "/tmp/project"
        )
        var session = AgentSession(
            id: "codex-desktop",
            projectDir: "/tmp/project",
            projectName: "project",
            agentSource: .codex,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        )
        session.rawSource = "codex-desktop"

        XCTAssertEqual(
            permissionTargetBundleId(event: event, sessions: [session]),
            "com.openai.codex"
        )
    }
}
