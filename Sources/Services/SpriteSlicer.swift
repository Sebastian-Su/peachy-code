// `slice`, `pixelData` and `segments` are adapted from AgentPet
// (https://github.com/ntd4996/agentpet), MIT License,
// Copyright (c) 2026 Nguyễn Thành Đạt. See ThirdPartyNotices.md.
import AppKit

/// Slices a spritesheet (the Codex / petdex pet format: one row per animation,
/// one column per frame) by detecting the transparent gutters between cells,
/// so no grid metadata is required.
enum SpriteSlicer {
    /// Columns and rows of the standard pet sheet.
    static let gridColumns = 8
    static let gridRows = 9

    /// Frames per sheet row, keyed by row index. On the standard 8 x 9 grid a row
    /// keeps its grid index even when an earlier row is blank, so a missing
    /// animation never shifts the ones after it; other sheets number their rows
    /// in order.
    static func rows(of image: CGImage) -> [Int: [CGImage]] {
        let clips = sliceWithBands(image)
        let cellHeight = image.height / gridRows
        let onGrid = image.width % gridColumns == 0 && image.height % gridRows == 0 && cellHeight > 0
            && clips.allSatisfy { $0.band.lower / cellHeight == ($0.band.upper - 1) / cellHeight }
        var result: [Int: [CGImage]] = [:]
        for (index, clip) in clips.enumerated() {
            result[onGrid ? clip.band.lower / cellHeight : index] = clip.frames
        }
        return result
    }

    /// Slices a spritesheet into clips (one per sheet row) using alpha gutter
    /// detection, so no grid metadata is required. Columns are detected within
    /// each row, so ragged sheets (rows with different frame counts or unaligned
    /// columns, e.g. AI-generated sheets) slice correctly. Uniform grids are
    /// unaffected: every row finds the same columns.
    static func slice(_ image: CGImage, alphaThreshold: UInt8 = 16) -> [[CGImage]] {
        sliceWithBands(image, alphaThreshold: alphaThreshold).map(\.frames)
    }

    private static func sliceWithBands(_ image: CGImage, alphaThreshold: UInt8 = 16) -> [(band: (lower: Int, upper: Int), frames: [CGImage])] {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let data = pixelData(image, width: w, height: h) else { return [] }

        var rowHas = [Bool](repeating: false, count: h)
        data.withUnsafeBufferPointer { buf in
            for y in 0..<h {
                let rowStart = y * w * 4
                for x in 0..<w where buf[rowStart + x * 4 + 3] > alphaThreshold {
                    rowHas[y] = true
                    break
                }
            }
        }
        let rowBands = segments(rowHas)
        guard !rowBands.isEmpty else { return [] }

        var clips: [(band: (lower: Int, upper: Int), frames: [CGImage])] = []
        data.withUnsafeBufferPointer { buf in
            for row in rowBands {
                var colHas = [Bool](repeating: false, count: w)
                for y in row.lower..<row.upper {
                    let rowStart = y * w * 4
                    for x in 0..<w where buf[rowStart + x * 4 + 3] > alphaThreshold {
                        colHas[x] = true
                    }
                }
                var clip: [CGImage] = []
                for col in segments(colHas) {
                    let rect = CGRect(x: col.lower, y: row.lower,
                                      width: col.upper - col.lower, height: row.upper - row.lower)
                    guard let cropped = image.cropping(to: rect) else { continue }
                    let fw = Int(rect.width), fh = Int(rect.height)
                    let space = CGColorSpaceCreateDeviceRGB()
                    let info = CGImageAlphaInfo.premultipliedLast.rawValue
                    guard let ctx = CGContext(data: nil, width: fw, height: fh,
                                             bitsPerComponent: 8, bytesPerRow: fw * 4,
                                             space: space, bitmapInfo: info) else { continue }
                    ctx.draw(cropped, in: CGRect(origin: .zero, size: CGSize(width: fw, height: fh)))
                    guard let frame = ctx.makeImage() else { continue }
                    clip.append(frame)
                }
                if !clip.isEmpty { clips.append((row, clip)) }
            }
        }
        return clips
    }

    private static func pixelData(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = data.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(data: ptr.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: info)
        }) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private static func segments(_ occupancy: [Bool]) -> [(lower: Int, upper: Int)] {
        var result: [(Int, Int)] = []
        var start: Int?
        for (i, filled) in occupancy.enumerated() {
            if filled, start == nil { start = i }
            else if !filled, let s = start { result.append((s, i)); start = nil }
        }
        if let s = start { result.append((s, occupancy.count)) }
        return result
    }
}
