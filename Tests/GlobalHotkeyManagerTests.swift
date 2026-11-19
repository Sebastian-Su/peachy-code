import ApplicationServices
import XCTest
@testable import PeachyPet

final class GlobalHotkeyManagerTests: XCTestCase {
    func testPlainEscapeDismissesNonPermissionCard() {
        XCTAssertEqual(
            GlobalHotkeyManager.plainEscapeAction(
                card: .toast,
                flags: [],
                permissionIsTerminalFallback: false
            ),
            .dismissCard
        )
    }

    func testPlainEscapePassesThroughForActionablePermission() {
        XCTAssertEqual(
            GlobalHotkeyManager.plainEscapeAction(
                card: .permission,
                flags: [],
                permissionIsTerminalFallback: false
            ),
            .passThrough
        )
    }

    func testPlainEscapeDismissesTerminalFallbackPermission() {
        XCTAssertEqual(
            GlobalHotkeyManager.plainEscapeAction(
                card: .permission,
                flags: [],
                permissionIsTerminalFallback: true
            ),
            .dismissTerminalFallback
        )
    }

    func testPlainEscapePassesThroughForExpandedPermission() {
        XCTAssertEqual(
            GlobalHotkeyManager.plainEscapeAction(
                card: .expandedPermission,
                flags: [],
                permissionIsTerminalFallback: true
            ),
            .passThrough
        )
    }

    func testModifiedEscapePassesThroughForTerminalFallbackPermission() {
        for flags: CGEventFlags in [.maskShift, .maskControl, .maskAlternate] {
            XCTAssertEqual(
                GlobalHotkeyManager.plainEscapeAction(
                    card: .permission,
                    flags: flags,
                    permissionIsTerminalFallback: true
                ),
                .passThrough
            )
        }
    }

    func testFallbackKeyLabelsUseReadableNames() {
        XCTAssertEqual(fallbackKeyCodeToString(46), "M")
        XCTAssertEqual(fallbackKeyCodeToString(26), "7")
        XCTAssertEqual(fallbackKeyCodeToString(53), "Esc")
    }

    func testUnknownKeyLabelDoesNotExposeRawKeyCode() {
        XCTAssertEqual(fallbackKeyCodeToString(255), "?")
    }
}

extension GlobalHotkeyManagerTests {
    func testHistoryChordRequiresDoubleCommandAndConsumesOnlyOneMatchingPress() {
        var chord = SessionResultHistoryChord()
        XCTAssertFalse(chord.consume(at: 10, matches: true))
        chord.arm(at: 10)
        XCTAssertTrue(chord.consume(at: 10.25, matches: true))
        XCTAssertFalse(chord.consume(at: 10.3, matches: true))
        chord.arm(at: 20)
        XCTAssertFalse(chord.consume(at: 20.1, matches: false))
        XCTAssertFalse(chord.consume(at: 20.2, matches: true))
        chord.arm(at: 30)
        XCTAssertFalse(chord.consume(at: 32, matches: true))
    }
}

extension GlobalHotkeyManagerTests {
    func testResultClaimsOnlyItsOwnDigitsAndYieldsToPermissionAndSwitcher() {
        XCTAssertEqual(ActiveCard.preferred(switcher: false, permission: false, result: true, toast: true), .result)
        XCTAssertEqual(ActiveCard.preferred(switcher: false, permission: true, result: true, toast: true), .permission)
        XCTAssertEqual(ActiveCard.preferred(switcher: true, permission: true, result: true, toast: true), .sessionSwitcher)
        XCTAssertEqual(ActiveCard.preferred(switcher: false, permission: false, result: false, toast: true), .toast)
        XCTAssertTrue(ActiveCard.result.acceptsNumber(1))
        XCTAssertTrue(ActiveCard.result.acceptsNumber(2))
        XCTAssertFalse(ActiveCard.result.acceptsNumber(3))
        XCTAssertTrue(ActiveCard.permission.acceptsNumber(9))
        XCTAssertEqual(GlobalHotkeyManager.plainEscapeAction(card: .result, flags: [],
                                                              permissionIsTerminalFallback: false), .dismissCard)
    }
}

final class SessionSwitcherShortcutTests: XCTestCase {
    func testSwitcherOpensDashboardPages() {
        XCTAssertEqual(GlobalHotkeyManager.switcherPage(keyCode: 35, card: .sessionSwitcher), .current)
        XCTAssertEqual(GlobalHotkeyManager.switcherPage(keyCode: 1, card: .sessionSwitcher), .services)
    }

    func testPageKeysBelongToTheSwitcherOnly() {
        // ⌘P on a permission card still expands it; ⌘S elsewhere stays the app's own Save.
        XCTAssertNil(GlobalHotkeyManager.switcherPage(keyCode: 35, card: .permission))
        XCTAssertNil(GlobalHotkeyManager.switcherPage(keyCode: 1, card: .none))
        XCTAssertNil(GlobalHotkeyManager.switcherPage(keyCode: 0, card: .sessionSwitcher))
    }
}

final class SessionSwitcherOrderTests: XCTestCase {
    private func session(_ id: String, _ phase: AgentSession.Phase, ago: TimeInterval) -> AgentSession {
        AgentSession(id: id, projectDir: nil, projectName: id, agentSource: .codex, status: .active, phase: phase,
                     eventCount: 1, startedAt: Date().addingTimeInterval(-ago), lastEventAt: Date().addingTimeInterval(-ago))
    }

    /// ⌘N picks the row drawn at N. A refresh while the switcher is open (a remote turn
    /// starting or ending) must not reorder the rows under the user's finger.
    func testRefreshKeepsTheOrderTheUserSees() {
        let store = SessionSwitcherStore()
        store.open(sessions: [session("a", .idle, ago: 10), session("b", .idle, ago: 20), session("c", .idle, ago: 30)])
        XCTAssertEqual(store.sessions.map(\.id), ["a", "b", "c"])

        // "c" starts running and "d" appears.
        store.refresh(sessions: [session("a", .idle, ago: 10), session("b", .idle, ago: 20),
                                 session("c", .running, ago: 0), session("d", .idle, ago: 5)])
        XCTAssertEqual(store.sessions.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(store.sessions[2].phase, .running, "rows still show the latest state")

        store.selectIndex(1)
        XCTAssertEqual(store.confirm()?.id, "b")
        store.close()
    }
}
