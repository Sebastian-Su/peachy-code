import AppKit
import XCTest
@testable import PeachyPet

final class ImageBackgroundRemoverTests: XCTestCase {
    func testFlatCornerBackgroundBecomesTransparentWhileCharacterRemainsOpaque() throws {
        let source = try makeWhiteImageWithPinkCenter()
        let output = try ImageBackgroundRemover.removeFlatBackground(from: source)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: output))

        XCTAssertLessThan(bitmap.colorAt(x: 1, y: 1)?.alphaComponent ?? 1, 0.05)
        XCTAssertGreaterThan(bitmap.colorAt(x: 16, y: 16)?.alphaComponent ?? 0, 0.95)
    }

    private func makeWhiteImageWithPinkCenter() throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSColor.systemPink.setFill()
        NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImageBackgroundRemoverTests", code: 1)
        }
        return png
    }
}
