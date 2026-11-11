import AppKit
import CryptoKit
import XCTest
@testable import PeachyPet

@MainActor
final class PeachyIconProviderTests: XCTestCase {
    func testSystemApplicationIconMatchesApproved02Artwork() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let info = try Data(contentsOf: project.appendingPathComponent("Info.plist"))
        let metadata = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        )
        let iconName = try XCTUnwrap(metadata["CFBundleIconFile"] as? String)
        let icon = project.appendingPathComponent("Sources/Resources/\(iconName).icns")
        XCTAssertNotNil(NSImage(contentsOf: icon), "The system icon must be decodable")
        let digest = SHA256.hash(data: try Data(contentsOf: icon))
            .map { String(format: "%02x", $0) }.joined()
        // Frozen from the user-approved 02 ICNS, independently of the production resource.
        XCTAssertEqual(
            digest, "bbc1d9a6368c2f7d272ebfaaff0ffdf2bb8d57bddc9ca4a54bb1caf56f075c86",
            "Finder and Dock must use the approved 02 artwork"
        )
    }

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
            try assertPixelsFormTransparentMonochromeTemplate(in: image, state: state)
        }
    }

    func testMenuBarSilhouettesMatchApprovedFullerMarksAtBothScales() throws {
        // Alpha snapshots from the approved templates; black/white ink is not part of the contract.
        let approved: [(PeachyIconProvider.MenuBarState, [Int: String])] = [
            (.idle, [
                18: "cc29b65cd3b3fcc03617f5c512e71743c7ebcf7c3c2c66e4a3cb2f6e1b55ff0f",
                36: "ea750157ea810a359ea500c4b6a626d8ec87ce07a587a20caa5b679fd32beb27"
            ]),
            (.working, [
                18: "edb81255e28dd9e3761b6b98ac9e1f2caf270ae8229747b2dc03043a09a8d4dc",
                36: "980987c5ba397217bf5494629b066218cc41cd19818cd1c496202b886e472f2b"
            ]),
            (.attention, [
                18: "41605de968a4ddace72e72484dc719e06ed6a7b2eee39eaef2c2425b5c9a39de",
                36: "1ec5cfda0ab760a2a2096976c28bb94c377db8756c2675d4b769d885ff74dbb5"
            ])
        ]
        for (state, hashes) in approved {
            let image = try XCTUnwrap(PeachyIconProvider.menuBarImage(for: state))
            for representation in image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                var alpha = Data()
                for y in 0..<representation.pixelsHigh {
                    for x in 0..<representation.pixelsWide {
                        let color = try XCTUnwrap(representation.colorAt(x: x, y: y))
                        alpha.append(UInt8((color.alphaComponent * 255).rounded()))
                    }
                }
                let digest = SHA256.hash(data: alpha).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(
                    digest, hashes[representation.pixelsWide], "\(state) must use the fuller silhouette"
                )
            }
        }
    }

    func testBrandMarkHasTransparentCorners() throws {
        let image = try XCTUnwrap(PeachyIconProvider.brandImage())
        let representation = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let corner = try XCTUnwrap(representation.colorAt(x: 0, y: 0))

        XCTAssertLessThan(corner.alphaComponent, 0.01)
    }

    func testWindowBrandMarkUsesApproved02Artwork() throws {
        let image = try XCTUnwrap(PeachyIconProvider.brandImage())
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 512)
        XCTAssertEqual(bitmap.pixelsHigh, 512)
        var rgba = Data()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                rgba.append(contentsOf: [
                    color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent
                ].map { UInt8(($0 * 255).rounded()) })
            }
        }
        let digest = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest, "37d6cd54a403e7e13fcd1e0cedb58cce4d2d3ae7cc3d045fcc8760c2eb333ac5",
            "All window brand marks must display the approved 02 kitten"
        )
    }

    private func assertPixelsFormTransparentMonochromeTemplate(
        in image: NSImage,
        state: PeachyIconProvider.MenuBarState
    ) throws {
        for representation in image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
            XCTAssertEqual(representation.pixelsWide, representation.pixelsHigh)
            let corner = try XCTUnwrap(representation.colorAt(x: 0, y: 0))
            XCTAssertLessThan(corner.alphaComponent, 0.01, "\(state) must have transparent corners")
            var visiblePixels = 0
            for y in 0..<representation.pixelsHigh {
                for x in 0..<representation.pixelsWide {
                    guard let color = representation.colorAt(x: x, y: y),
                          color.alphaComponent > 0,
                          let rgb = color.usingColorSpace(.deviceRGB) else { continue }
                    visiblePixels += 1
                    XCTAssertEqual(
                        rgb.redComponent, rgb.greenComponent, accuracy: 0.01, "\(state) must be monochrome"
                    )
                    XCTAssertEqual(
                        rgb.greenComponent, rgb.blueComponent, accuracy: 0.01, "\(state) must be monochrome"
                    )
                }
            }
            XCTAssertGreaterThan(visiblePixels, 0, "\(state) must not be blank")
        }
    }
}
