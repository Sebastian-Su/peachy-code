import CoreGraphics

/// Frame rates for spritesheet pets: busy states move faster than quiet ones.
enum SpriteTiming {
    static let framesPerSecond: [String: Double] = ["Working": 8, "Needs Attention": 4, "Idle": 3, "Thinking": 3]

    static func fps(for nodeId: String, in config: PeachyAnimationConfig) -> Double {
        let name = config.nodes.first { $0.id == nodeId }?.name ?? ""
        return framesPerSecond[name] ?? 3
    }
}

/// Where each frame of a spritesheet pet is drawn, following AgentPet's Windows
/// renderer: bottom-centred on whole pixels, one scale for every frame of the pet
/// (not just one row) so switching state never changes its size. The pet fills the
/// canvas; rounding the scale down to a whole number left a 203 px frame at 1x in a
/// 300 px window, a third of it empty.
struct SpriteLayout {
    let canvas: CGSize
    let scale: CGFloat

    init(frameSizes: [CGSize], canvas: CGSize) {
        self.canvas = canvas
        let maxW = frameSizes.map(\.width).max() ?? 1
        let maxH = frameSizes.map(\.height).max() ?? 1
        scale = min(canvas.width / max(maxW, 1), canvas.height / max(maxH, 1))
    }

    /// Nearest-neighbour keeps pixel art crisp only at whole-number scales; anything
    /// else needs smoothing, or soft-edged sheets turn jagged.
    var isWholeScale: Bool { abs(scale - scale.rounded()) < 0.001 && scale >= 1 }

    /// Frame rect in canvas pixels, origin at the top-left.
    func rect(for size: CGSize) -> CGRect {
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: ((canvas.width - w) / 2).rounded(), y: (canvas.height - h).rounded(), width: w, height: h)
    }
}
