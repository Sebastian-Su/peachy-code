import AppKit
import AVFoundation
import Foundation

struct GeneratedMedia {
    let data: Data
    let fileExtension: String
    let mediaType: MascotMediaType
}

struct AnchorGenerationRequest {
    let project: MascotProject
    let state: MascotStateDraft
    let referenceURL: URL
    let styleReferenceURL: URL?
}

struct LoopGenerationRequest {
    let project: MascotProject
    let state: MascotStateDraft
    let anchorURL: URL
}

struct TransitionGenerationRequest {
    let project: MascotProject
    let transition: MascotTransitionDraft
    let sourceAnchorURL: URL
    let targetAnchorURL: URL
}

protocol MediaGenerationProvider {
    var id: String { get }
    var displayName: String { get }

    func generateAnchor(request: AnchorGenerationRequest) async throws -> GeneratedMedia
    func generateLoop(request: LoopGenerationRequest) async throws -> GeneratedMedia
    func generateTransition(request: TransitionGenerationRequest) async throws -> GeneratedMedia
}

enum MediaGenerationProviderError: LocalizedError {
    case invalidReference
    case invalidResponse
    case requestFailed(Int)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidReference: t("creator.error.provider_reference")
        case .invalidResponse: t("creator.error.provider_response")
        case .requestFailed(let status): String(format: t("creator.error.provider_http"), status)
        case .encodingFailed(let message): String(format: t("creator.error.video_encoding"), message)
        }
    }
}

/// Offline provider used to exercise the entire creation pipeline without spending credits.
/// It keeps the reference image as every anchor and renders still, seamless HEVC clips.
struct MockMediaGenerationProvider: MediaGenerationProvider {
    static let providerID = "local-mock"
    let id = providerID
    let displayName = "Local Mock"

    func generateAnchor(request: AnchorGenerationRequest) async throws -> GeneratedMedia {
        let data = try Data(contentsOf: request.referenceURL)
        guard NSImage(data: data) != nil else { throw MediaGenerationProviderError.invalidReference }
        return GeneratedMedia(data: data, fileExtension: "png", mediaType: .image)
    }

    func generateLoop(request: LoopGenerationRequest) async throws -> GeneratedMedia {
        let data = try await StillVideoRenderer.render(
            imageURL: request.anchorURL,
            duration: request.state.loopDuration
        )
        return GeneratedMedia(data: data, fileExtension: "mov", mediaType: .video)
    }

    func generateTransition(request: TransitionGenerationRequest) async throws -> GeneratedMedia {
        let data = try await StillVideoRenderer.render(
            imageURL: request.targetAnchorURL,
            duration: request.transition.duration
        )
        return GeneratedMedia(data: data, fileExtension: "mov", mediaType: .video)
    }
}

struct HTTPMediaProviderConfiguration: Codable, Equatable {
    var id: String
    var displayName: String
    var baseURL: URL
    var imagePath: String
    var videoPath: String
    var imageModel: String
    var videoModel: String
    var apiKeyHeader: String
}

/// JSON-over-HTTP adapter intended for personal gateways and MCP-to-HTTP bridges.
/// Request images are base64 encoded. Responses may contain either `dataBase64` or `downloadURL`.
struct HTTPMediaGenerationProvider: MediaGenerationProvider {
    let configuration: HTTPMediaProviderConfiguration
    let apiKey: String
    var id: String { configuration.id }
    var displayName: String { configuration.displayName }

    func generateAnchor(request: AnchorGenerationRequest) async throws -> GeneratedMedia {
        try await call(
            path: configuration.imagePath,
            body: [
                "kind": "anchor",
                "model": configuration.imageModel,
                "prompt": combinedPrompt(project: request.project, motionPrompt: request.state.prompt),
                "referenceBase64": try Data(contentsOf: request.referenceURL).base64EncodedString(),
                "styleReferenceBase64": try request.styleReferenceURL.map { try Data(contentsOf: $0).base64EncodedString() },
            ],
            defaultExtension: "png",
            mediaType: .image
        )
    }

    func generateLoop(request: LoopGenerationRequest) async throws -> GeneratedMedia {
        try await call(
            path: configuration.videoPath,
            body: [
                "kind": "loop",
                "model": configuration.videoModel,
                "prompt": combinedPrompt(
                    project: request.project,
                    motionPrompt: request.state.prompt + ", return exactly to the supplied anchor frame"
                ),
                "startFrameBase64": try Data(contentsOf: request.anchorURL).base64EncodedString(),
                "endFrameBase64": try Data(contentsOf: request.anchorURL).base64EncodedString(),
                "durationSeconds": request.state.loopDuration,
            ],
            defaultExtension: "mov",
            mediaType: .video
        )
    }

    func generateTransition(request: TransitionGenerationRequest) async throws -> GeneratedMedia {
        try await call(
            path: configuration.videoPath,
            body: [
                "kind": "transition",
                "model": configuration.videoModel,
                "prompt": combinedPrompt(project: request.project, motionPrompt: request.transition.prompt),
                "startFrameBase64": try Data(contentsOf: request.sourceAnchorURL).base64EncodedString(),
                "endFrameBase64": try Data(contentsOf: request.targetAnchorURL).base64EncodedString(),
                "durationSeconds": request.transition.duration,
            ],
            defaultExtension: "mov",
            mediaType: .video
        )
    }

    private func combinedPrompt(project: MascotProject, motionPrompt: String) -> String {
        [project.stylePrompt, motionPrompt, "clean removable background, preserve character identity"]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private func call(
        path: String,
        body: [String: Any?],
        defaultExtension: String,
        mediaType: MascotMediaType
    ) async throws -> GeneratedMedia {
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: configuration.apiKeyHeader)
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body.compactMapValues { $0 },
            options: []
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MediaGenerationProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MediaGenerationProviderError.requestFailed(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(HTTPMediaResponse.self, from: data)
        let mediaData: Data
        if let encoded = decoded.dataBase64, let value = Data(base64Encoded: encoded) {
            mediaData = value
        } else if let downloadURL = decoded.downloadURL {
            mediaData = try await URLSession.shared.data(from: downloadURL).0
        } else {
            throw MediaGenerationProviderError.invalidResponse
        }
        return GeneratedMedia(
            data: mediaData,
            fileExtension: decoded.fileExtension ?? defaultExtension,
            mediaType: mediaType
        )
    }
}

private struct HTTPMediaResponse: Decodable {
    let dataBase64: String?
    let downloadURL: URL?
    let fileExtension: String?
}

private enum StillVideoRenderer {
    static func render(imageURL: URL, duration: Double, fps: Int = 15) async throws -> Data {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw MediaGenerationProviderError.invalidReference
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("peachy-mock-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }

        let size = fittedSize(width: cgImage.width, height: cgImage.height, maximum: 512)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaGenerationProviderError.encodingFailed(t("creator.error.hevc_writer_unavailable"))
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaGenerationProviderError.encodingFailed(writer.error.map(String.init(describing:)) ?? "writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(2, Int(duration * Double(fps)))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(4))
            }
            guard let buffer = makePixelBuffer(image: cgImage, width: size.width, height: size.height),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                writer.cancelWriting()
                throw MediaGenerationProviderError.encodingFailed(writer.error.map(String.init(describing:)) ?? "frame append failed")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw MediaGenerationProviderError.encodingFailed(writer.error.map(String.init(describing:)) ?? "writer did not finish")
        }
        return try Data(contentsOf: output)
    }

    private static func fittedSize(width: Int, height: Int, maximum: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maximum) / Double(max(width, height)))
        let scaledWidth = max(2, Int(Double(width) * scale) / 2 * 2)
        let scaledHeight = max(2, Int(Double(height) * scale) / 2 * 2)
        return (scaledWidth, scaledHeight)
    }

    private static func makePixelBuffer(image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
