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
