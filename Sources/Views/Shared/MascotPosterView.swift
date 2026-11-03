import SwiftUI
import AVFoundation

/// Where a still image of a mascot comes from. Video-only mascots (made in the
/// creation center or imported locally) have no thumbnail, so a frame of their
/// idle loop stands in.
enum MascotPoster: Equatable {
    case image(URL)
    case videoFrame(URL)

    static func source(for config: PeachyAnimationConfig) -> MascotPoster? {
        let initial = config.nodes.first { $0.id == config.initialNode } ?? config.nodes.first
        if let thumb = initial?.transparentThumbnailUrl, let url = URL(string: thumb) {
            return .image(url)
        }
        let idleLoop = config.edges.first { $0.isLoop && $0.source == config.initialNode }
            ?? config.edges.first { $0.source == config.initialNode }
        // AVFoundation cannot decode WebM, so only the HEVC rendition is usable here.
        if let hevc = idleLoop?.videos.hevc, let url = URL(string: hevc) {
            return .videoFrame(url)
        }
        return nil
    }
}

/// Still image of a mascot, either its thumbnail or a frame of its idle video.
struct MascotPosterView: View {
    let config: PeachyAnimationConfig?
    @State private var frame: NSImage?

    private static var frameCache: [URL: NSImage] = [:]

    var body: some View {
        Group {
            switch config.flatMap(MascotPoster.source(for:)) {
            case .image(let url):
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Color.clear
                }
            case .videoFrame(let url):
                if let frame {
                    Image(nsImage: frame).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.clear.task(id: url) { frame = await Self.loadFrame(url) }
                }
            case nil:
                Color.clear
            }
        }
    }

    private static func loadFrame(_ url: URL) async -> NSImage? {
        if let cached = frameCache[url] { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        guard let (cgImage, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        frameCache[url] = image
        return image
    }
}
