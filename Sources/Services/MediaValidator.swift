import AppKit
import AVFoundation
import Foundation

protocol MascotMediaValidating {
    func validateImage(at url: URL) throws -> MascotMediaValidation
    func validateLoop(videoURL: URL, anchorURL: URL) async throws -> MascotMediaValidation
    func validateTransition(videoURL: URL, sourceAnchorURL: URL, targetAnchorURL: URL) async throws -> MascotMediaValidation
}

enum MediaValidatorError: LocalizedError {
    case invalidImage
    case invalidVideo
    case frameExtractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: t("creator.error.invalid_image")
        case .invalidVideo: t("creator.error.invalid_video")
        case .frameExtractionFailed: t("creator.error.frame_extraction")
        }
    }
}

struct MediaValidator: MascotMediaValidating {
    static let defaultSimilarityThreshold = 0.97
    let similarityThreshold: Double

    init(similarityThreshold: Double = Self.defaultSimilarityThreshold) {
        self.similarityThreshold = similarityThreshold
    }

    func validateImage(at url: URL) throws -> MascotMediaValidation {
        guard let image = NSImage(contentsOf: url), image.isValid else {
            throw MediaValidatorError.invalidImage
        }
        return MascotMediaValidation(passed: true, seamScore: nil, messages: [])
    }

    func validateLoop(videoURL: URL, anchorURL: URL) async throws -> MascotMediaValidation {
        let (first, last, hasAlpha, isHEVC) = try await endpointFrames(videoURL: videoURL)
        let anchor = try Data(contentsOf: anchorURL)
        let firstScore = try Self.imageSimilarity(first, anchor)
        let lastScore = try Self.imageSimilarity(last, anchor)
        let score = min(firstScore, lastScore)
        return MascotMediaValidation(
            passed: score >= similarityThreshold && hasAlpha && isHEVC,
            seamScore: score,
            messages: validationMessages(
                endpointPassed: score >= similarityThreshold,
                endpointMessage: t("creator.error.loop_endpoints"),
                hasAlpha: hasAlpha,
                isHEVC: isHEVC
            )
        )
    }

    func validateTransition(
        videoURL: URL,
        sourceAnchorURL: URL,
        targetAnchorURL: URL
    ) async throws -> MascotMediaValidation {
        let (first, last, hasAlpha, isHEVC) = try await endpointFrames(videoURL: videoURL)
        let sourceScore = try Self.imageSimilarity(first, Data(contentsOf: sourceAnchorURL))
        let targetScore = try Self.imageSimilarity(last, Data(contentsOf: targetAnchorURL))
        let score = min(sourceScore, targetScore)
        return MascotMediaValidation(
            passed: score >= similarityThreshold && hasAlpha && isHEVC,
            seamScore: score,
            messages: validationMessages(
                endpointPassed: score >= similarityThreshold,
                endpointMessage: t("creator.error.transition_endpoints"),
                hasAlpha: hasAlpha,
                isHEVC: isHEVC
            )
        )
    }

    static func imageSimilarity(_ lhs: Data, _ rhs: Data) throws -> Double {
        guard let left = NSImage(data: lhs)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let right = NSImage(data: rhs)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw MediaValidatorError.invalidImage
        }
        let width = 64
        let height = 64
        let leftPixels = try rgbaPixels(left, width: width, height: height)
        let rightPixels = try rgbaPixels(right, width: width, height: height)
        var difference: UInt64 = 0
        for index in stride(from: 0, to: leftPixels.count, by: 4) {
            let leftAlpha = Int(leftPixels[index + 3])
            let rightAlpha = Int(rightPixels[index + 3])
            let alphaWeight = max(leftAlpha, rightAlpha)
            difference += UInt64(abs(leftAlpha - rightAlpha) * 255)
            for channel in 0..<3 {
                difference += UInt64(abs(Int(leftPixels[index + channel]) - Int(rightPixels[index + channel])) * alphaWeight)
            }
        }
        let maximum = UInt64(width * height * 4 * 255 * 255)
        return max(0, 1 - Double(difference) / Double(maximum))
    }

    private func endpointFrames(videoURL: URL) async throws -> (Data, Data, Bool, Bool) {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw MediaValidatorError.invalidVideo }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let finalTime = CMTime(seconds: max(0, seconds - 1.0 / 30.0), preferredTimescale: 600)
        guard let first = try? generator.copyCGImage(at: .zero, actualTime: nil),
              let last = try? generator.copyCGImage(at: finalTime, actualTime: nil) else {
            throw MediaValidatorError.frameExtractionFailed
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let descriptions = try await tracks.first?.load(.formatDescriptions) ?? []
        let hasAlpha = descriptions.contains { description in
            guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? else {
                return false
            }
            return extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool == true
        }
        let isHEVC = descriptions.contains {
            let subtype = CMFormatDescriptionGetMediaSubType($0)
            return subtype == kCMVideoCodecType_HEVC || subtype == kCMVideoCodecType_HEVCWithAlpha
        }
        return (try Self.pngData(first), try Self.pngData(last), hasAlpha, isHEVC)
    }

    private func validationMessages(
        endpointPassed: Bool,
        endpointMessage: String,
        hasAlpha: Bool,
        isHEVC: Bool
    ) -> [String] {
        var messages: [String] = []
        if !endpointPassed { messages.append(endpointMessage) }
        if !hasAlpha { messages.append(t("creator.error.missing_alpha")) }
        if !isHEVC { messages.append(t("creator.error.not_hevc")) }
        return messages
    }

    private static func rgbaPixels(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MediaValidatorError.invalidImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw MediaValidatorError.invalidImage
        }
        return data
    }
}
