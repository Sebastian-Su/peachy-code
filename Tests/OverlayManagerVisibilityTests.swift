import AppKit
import XCTest
@testable import PeachyPet

final class OverlayManagerVisibilityTests: XCTestCase {
    @MainActor
    func testStartingMascotRectClampsSavedOffscreenOrigin() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 700)

        let rect = OverlayManager.startingMascotRect(
            savedX: 5000,
            savedY: 5000,
            sidePixels: 150,
            screenFrame: screen
        )

        XCTAssertEqual(rect.width, 150, accuracy: 0.001)
        XCTAssertEqual(rect.height, 150, accuracy: 0.001)
        XCTAssertEqual(rect.origin.x, 850, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 550, accuracy: 0.001)
    }

    @MainActor
    func testStartingMascotRectUsesMinimumSizeWhenInputIsZero() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 700)

        let rect = OverlayManager.startingMascotRect(
            savedX: 0,
            savedY: 0,
            sidePixels: 0,
            screenFrame: screen
        )

        XCTAssertEqual(rect.width, 50, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
        XCTAssertEqual(rect.origin.x, 910, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 40, accuracy: 0.001)
    }

    @MainActor
    func testClampedMascotRectCapsSizeToScreenBounds() {
        let screen = NSRect(x: 100, y: 200, width: 120, height: 120)

        let rect = OverlayManager.clampedMascotRect(
            origin: CGPoint(x: 140, y: 230),
            side: 400,
            screenFrame: screen
        )

        XCTAssertEqual(rect.width, 120, accuracy: 0.001)
        XCTAssertEqual(rect.height, 120, accuracy: 0.001)
        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, 200, accuracy: 0.001)
    }

    // MARK: - Which display hosts the mascot

    /// Two displays side by side: primary at the origin, secondary to its right.
    private let primary = NSRect(x: 0, y: 0, width: 1000, height: 700)
    private let secondary = NSRect(x: 1000, y: 0, width: 800, height: 600)

    @MainActor
    func testScreenFrameHostingPicksDisplayWithLargestOverlap() {
        // 60 px on the secondary display, 40 px on the primary one.
        let rect = NSRect(x: 960, y: 100, width: 100, height: 100)

        let frame = OverlayManager.screenFrame(
            hosting: rect,
            candidates: [primary, secondary],
            fallback: primary
        )

        XCTAssertEqual(frame, secondary)
    }

    @MainActor
    func testScreenFrameHostingFallsBackToNearestWhenFullyOffscreen() {
        // Dragged past the right edge of the secondary display — overlaps nothing.
        let rect = NSRect(x: 2000, y: 100, width: 100, height: 100)

        let frame = OverlayManager.screenFrame(
            hosting: rect,
            candidates: [primary, secondary],
            fallback: primary
        )

        XCTAssertEqual(frame, secondary)
    }

    @MainActor
    func testScreenFrameHostingUsesFallbackWithoutDisplays() {
        let frame = OverlayManager.screenFrame(
            hosting: NSRect(x: 10, y: 10, width: 100, height: 100),
            candidates: [],
            fallback: primary
        )

        XCTAssertEqual(frame, primary)
    }

    @MainActor
    func testDragEndSnapReturnsMascotFullyOntoItsOwnDisplay() {
        // Released half-way off the bottom-right corner of the secondary display.
        let dragged = NSRect(x: 1760, y: -40, width: 100, height: 100)
        let host = OverlayManager.screenFrame(
            hosting: dragged,
            candidates: [primary, secondary],
            fallback: primary
        )

        let snapped = OverlayManager.clampedMascotRect(
            origin: dragged.origin,
            side: dragged.width,
            screenFrame: host
        )

        XCTAssertEqual(host, secondary)
        XCTAssertTrue(secondary.contains(snapped), "snapped rect \(snapped) must be fully on \(secondary)")
        // Nearest fully-visible spot is the corner it was dragged out of, not the centre.
        XCTAssertEqual(snapped.origin.x, 1700, accuracy: 0.001)
        XCTAssertEqual(snapped.origin.y, 0, accuracy: 0.001)
    }
}
