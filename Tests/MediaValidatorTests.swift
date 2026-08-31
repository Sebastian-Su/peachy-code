import AppKit
import XCTest
@testable import PeachyPet

final class MediaValidatorTests: XCTestCase {
    func testIdenticalImagesHavePerfectSimilarity() throws {
        let image = try makeImageData(color: .systemPink)
        let score = try MediaValidator.imageSimilarity(image, image)
        XCTAssertEqual(score, 1, accuracy: 0.0001)
    }

    func testDifferentImagesDoNotPassDefaultAnchorThreshold() throws {
        let pink = try makeImageData(color: .systemPink)
        let blue = try makeImageData(color: .systemBlue)
        XCTAssertLessThan(try MediaValidator.imageSimilarity(pink, blue), MediaValidator.defaultSimilarityThreshold)
    }

    private func makeImageData(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MediaValidatorTests", code: 1)
        }
        return png
    }
}
