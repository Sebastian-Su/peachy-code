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
