import AppKit
import Foundation

enum ImageBackgroundRemoverError: LocalizedError {
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The image could not be decoded for background removal"
        case .encodingFailed: "The transparent image could not be encoded"
        }
    }
}

/// Removes a nearly uniform background sampled from the four image corners.
/// This deliberately handles only flat studio/chroma backgrounds; ambiguous scenes are left for review.
enum ImageBackgroundRemover {
    static func removeFlatBackground(
        from data: Data,
        transparentDistance: CGFloat = 0.12,
        opaqueDistance: CGFloat = 0.30
    ) throws -> Data {
        guard let source = NSImage(data: data),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageBackgroundRemoverError.invalidImage
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageBackgroundRemoverError.invalidImage }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cornerOffsets = [0, (width - 1) * 4, (height - 1) * bytesPerRow, (height - 1) * bytesPerRow + (width - 1) * 4]
        if cornerOffsets.contains(where: { pixels[$0 + 3] < 25 }) {
            return data
        }
        let background = (
            red: cornerOffsets.map { CGFloat(pixels[$0]) / 255 }.reduce(0, +) / 4,
            green: cornerOffsets.map { CGFloat(pixels[$0 + 1]) / 255 }.reduce(0, +) / 4,
            blue: cornerOffsets.map { CGFloat(pixels[$0 + 2]) / 255 }.reduce(0, +) / 4
        )

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let red = CGFloat(pixels[offset]) / 255 - background.red
                let green = CGFloat(pixels[offset + 1]) / 255 - background.green
                let blue = CGFloat(pixels[offset + 2]) / 255 - background.blue
                let distance = sqrt(red * red + green * green + blue * blue)
                let coverage = max(0, min(1, (distance - transparentDistance) / (opaqueDistance - transparentDistance)))
                pixels[offset] = UInt8(CGFloat(pixels[offset]) * coverage)
                pixels[offset + 1] = UInt8(CGFloat(pixels[offset + 1]) * coverage)
                pixels[offset + 2] = UInt8(CGFloat(pixels[offset + 2]) * coverage)
                pixels[offset + 3] = UInt8(CGFloat(pixels[offset + 3]) * coverage)
            }
        }

        guard let outputImage = context.makeImage(),
              let output = NSBitmapImageRep(cgImage: outputImage).representation(using: .png, properties: [:]) else {
            throw ImageBackgroundRemoverError.encodingFailed
        }
        return output
    }
}
