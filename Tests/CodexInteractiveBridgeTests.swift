import Foundation
import XCTest
@testable import PeachyPet

final class CodexInteractiveBridgeTests: XCTestCase {
    func testFocusSelectsProcessByMatchingCwd() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "sid-1",
            cwd: "/Users/test/project",
            toolName: "exec_command",
            client: "codex-cli"
        )

        let processes = [
            CodexInteractiveBridge.ProcessInfo(pid: 10, cwd: "/tmp/other", tty: "/dev/ttys001"),
            CodexInteractiveBridge.ProcessInfo(pid: 11, cwd: "/Users/test/project", tty: "/dev/ttys002"),
        ]

        var activatedPid: Int?
        let ok = CodexInteractiveBridge.focus(event: event, processInfos: processes) { pid in
            activatedPid = pid
            return true
        }

        XCTAssertTrue(ok)
        XCTAssertEqual(activatedPid, 11)
    }

    func testFocusReturnsFalseWhenAmbiguousWithoutCwdMatch() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "sid-2",
            cwd: nil,
            toolName: "exec_command",
            client: "codex-cli"
        )

        let processes = [
            CodexInteractiveBridge.ProcessInfo(pid: 20, cwd: "/a", tty: "/dev/ttys003"),
            CodexInteractiveBridge.ProcessInfo(pid: 21, cwd: "/b", tty: "/dev/ttys004"),
        ]

        let ok = CodexInteractiveBridge.focus(event: event, processInfos: processes) { _ in
            XCTFail("Activator should not be called when process selection is ambiguous")
            return false
        }

        XCTAssertFalse(ok)
    }

    /// Desktop sessions route to the Codex app by host; with no cwd match the bridge must not
    /// guess a terminal, since the newest TTY belongs to some other session.
    func testFocusDoesNotGuessTerminalWithoutCwdMatch() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "sid-2b",
            cwd: nil,
            toolName: "exec_command",
            client: "codex-desktop"
        )

        let processes = [
            CodexInteractiveBridge.ProcessInfo(pid: 120, cwd: nil, tty: "/dev/ttys010"),
            CodexInteractiveBridge.ProcessInfo(pid: 125, cwd: nil, tty: "/dev/ttys011"),
        ]

        var activatedPid: Int?
        let ok = CodexInteractiveBridge.focus(event: event, processInfos: processes) { pid in
            activatedPid = pid
            return true
        }

        XCTAssertFalse(ok)
        XCTAssertNil(activatedPid)
    }

    func testFocusRejectsClaudeEvents() {
        let event = AgentEvent(
            hookEventName: HookEventType.permissionRequest.rawValue,
            sessionId: "sid-3",
            cwd: "/Users/test/project",
            toolName: "Bash",
            source: "claude"
        )

        let ok = CodexInteractiveBridge.focus(
            event: event,
            processInfos: [CodexInteractiveBridge.ProcessInfo(pid: 42, cwd: "/Users/test/project", tty: "/dev/ttys009")]
        ) { _ in
            XCTFail("Activator should not be called for Claude events")
            return false
        }

        XCTAssertFalse(ok)
    }
}
