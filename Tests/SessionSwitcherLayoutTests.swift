import AppKit
import SwiftUI
import XCTest
@testable import PeachyPet

final class SessionSwitcherLayoutTests: XCTestCase {
    @MainActor
    func testLongSessionListFitsWithinMaximumHeight() {
        let store = SessionSwitcherStore()
        store.open(sessions: sessions(count: 25))

        let view = SessionSwitcherView(maximumHeight: 500)
            .environment(store)
            .environment(GlobalHotkeyManager())
        let hostingView = NSHostingView(rootView: view)

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 500.5)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 400)
        store.close()
    }

    @MainActor
    func testShortSessionListKeepsContentDrivenHeight() {
        let store = SessionSwitcherStore()
        store.open(sessions: sessions(count: 2))

        let view = SessionSwitcherView(maximumHeight: 500)
            .environment(store)
            .environment(GlobalHotkeyManager())
        let hostingView = NSHostingView(rootView: view)

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThan(hostingView.fittingSize.height, 150)
        store.close()
    }

    func testMaximumHeightUsesVisibleScreenFractionAndAccountsForScale() {
        XCTAssertEqual(
            sessionSwitcherMaximumHeight(visibleScreenHeight: 1_000, scale: 1),
            720,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sessionSwitcherMaximumHeight(visibleScreenHeight: 1_000, scale: 2),
            360,
            accuracy: 0.001
        )
    }

    @MainActor
    func testPermissionPanelHeightNeverExceedsVisibleScreenBounds() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        XCTAssertEqual(
            OverlayManager.boundedPermissionPanelHeight(
                contentHeight: 1_600,
                screenFrame: screen
            ),
            868,
            accuracy: 0.001
        )
        XCTAssertEqual(
            OverlayManager.boundedPermissionPanelHeight(
                contentHeight: 420,
                screenFrame: screen
            ),
            420,
            accuracy: 0.001
        )
    }

    private func sessions(count: Int) -> [AgentSession] {
        let now = Date()
        return (0..<count).map { index in
            AgentSession(
                id: "session-\(index)",
                projectDir: "/tmp/session-\(index)",
                projectName: "Project \(index)",
                agentSource: .claudeCode,
                status: .active,
                phase: .running,
                eventCount: 1,
                startedAt: now.addingTimeInterval(TimeInterval(-index)),
                lastEventAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
    }
}
