import AppKit
import XCTest
@testable import PeachyPet

@MainActor
final class PeachyIconProviderTests: XCTestCase {
    func testMenuBarStatesLoadAsTransparentTemplateImagesAtBothScales() throws {
        for state in PeachyIconProvider.MenuBarState.allCases {
            let image = try XCTUnwrap(PeachyIconProvider.menuBarImage(for: state))

            XCTAssertTrue(image.isTemplate, "\(state) must follow the macOS menu bar appearance")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertEqual(
                Set(image.representations.map(\.pixelsWide)),
                Set([18, 36]),
                "\(state) must bundle 1x and 2x representations"
            )
            try assertVisiblePixelsAreWhite(in: image, state: state)
        }
    }

    func testBrandMarkHasTransparentCorners() throws {
        let image = try XCTUnwrap(PeachyIconProvider.brandImage())
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let corner = try XCTUnwrap(representation.colorAt(x: 0, y: 0))

        XCTAssertLessThan(corner.alphaComponent, 0.01)
    }

    private func assertVisiblePixelsAreWhite(
        in image: NSImage,
        state: PeachyIconProvider.MenuBarState
    ) throws {
        for representation in image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
            for y in 0..<representation.pixelsHigh {
                for x in 0..<representation.pixelsWide {
                    guard let color = representation.colorAt(x: x, y: y),
                          color.alphaComponent > 0,
                          let rgb = color.usingColorSpace(.deviceRGB) else { continue }
                    XCTAssertEqual(rgb.redComponent, 1, accuracy: 0.01, "\(state) contains non-white pixels")
                    XCTAssertEqual(rgb.greenComponent, 1, accuracy: 0.01, "\(state) contains non-white pixels")
                    XCTAssertEqual(rgb.blueComponent, 1, accuracy: 0.01, "\(state) contains non-white pixels")
                }
            }
        }
    }
}
