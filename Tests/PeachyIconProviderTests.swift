import AppKit
import CryptoKit
import XCTest
@testable import PeachyPet

@MainActor
final class PeachyIconProviderTests: XCTestCase {
    func testSystemApplicationIconMatchesApprovedScreenCatArtwork() throws {
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
        // Frozen from an independent raster export of the approved B screen-cat artwork.
        XCTAssertEqual(
            digest, "ba8933ec44c5f4a8f038d1cf8b6fcf2e23c5366348f886d04e5103184a31c301",
            "Finder and Dock must use the approved B screen-cat artwork"
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

    func testMenuBarSilhouettesMatchApprovedScreenCatAtBothScales() throws {
        // Independent raster exports of approved 02, with state expressions on the same cat frame.
        let approved: [(PeachyIconProvider.MenuBarState, [Int: String])] = [
            (.idle, [
                18: "6e295f3a45a405c6b0ca9954fe949d2907c76d53d21a71ab21899d858db4724a",
                36: "998a8f405babcb9126590a44133c36f1f064e4fc68b97ecd247c3dd7dcd473d8"
            ]),
            (.working, [
                18: "4f66cec9b0fd4b3fedb1951be4821fb81fae69e016a0a427ab181f90fb19fe46",
                36: "1ecf80078d0b7989c0742ab85d6a5645335dcb356e940812a85ab630b115062e"
            ]),
            (.attention, [
                18: "43629dc84d03dee5bf421e7a08b864c0e77fb76b29787987f337cb22f9d50416",
                36: "04a2503a9f37867f376dfdb8c399af12e710cdab9ff60428534d0f4bf154415d"
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
                    digest, hashes[representation.pixelsWide], "\(state) must use the approved screen-cat silhouette"
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

    func testDocumentationHeaderUsesApprovedScreenCatArtwork() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let image = project.appendingPathComponent("Sources/Resources/Images/app-icon.png")
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest, "87f7ada3e3718a181dc173fff54052ae7025176c443310035e230e2a152b36c2",
            "The existing documentation header must use the same approved B artwork"
        )
    }

    func testWindowBrandMarkUsesApprovedScreenCatArtwork() throws {
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
        // Frozen by decoding the independent approved export through AppKit;
        // its alpha/color decoding differs from raw Pillow RGBA bytes.
        XCTAssertEqual(
            digest, "445e790a96b3c846128bbe5f7426a47cf2a09806016274c18333602f50b03c8f",
            "All window brand marks must display the approved B screen cat"
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
