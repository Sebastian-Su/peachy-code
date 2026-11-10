// The frame timer (`restartTimer`/`advance`) is adapted from AgentPet's
// SpriteLayerNSView (https://github.com/ntd4996/agentpet), MIT License,
// Copyright (c) 2026 Nguyễn Thành Đạt. See ThirdPartyNotices.md.
import SwiftUI
import AppKit

/// Sliced frames of a sheet, cached by sheet URL so switching pets back and forth stays cheap.
@MainActor
enum SpriteSheetCache {
    private static var cache: [URL: [Int: [CGImage]]] = [:]

    static func rows(for url: URL) -> [Int: [CGImage]] {
        if let rows = cache[url] { return rows }
        guard let image = NSImage(contentsOf: url) else { return [:] }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [:] }
        let rows = SpriteSlicer.rows(of: cg)
        cache = [url: rows] // one pet on screen at a time
        return rows
    }
}

/// Plays the state machine's current sheet row on the overlay, in place of the video player.
struct SpriteSheetPlayer: NSViewRepresentable {
    let stateMachine: OverlayStateMachine

    func makeNSView(context: Context) -> SpriteSheetView {
        let view = SpriteSheetView()
        view.stateMachine = stateMachine
        view.reload()
        return view
    }

    func updateNSView(_ view: SpriteSheetView, context: Context) {
        view.stateMachine = stateMachine
        view.show(row: stateMachine.currentSpriteRow, node: stateMachine.currentNodeId)
    }

    static func dismantleNSView(_ view: SpriteSheetView, coordinator: ()) {
        view.teardown()
    }
}

final class SpriteSheetView: NSView {
    weak var stateMachine: OverlayStateMachine?
    private var rows: [Int: [CGImage]] = [:]
    private var placement: SpriteLayout?
    private var frames: [CGImage] = []
    private var row: Int?
    private var node: String?
    private var index = 0
    private var timer: Timer?
    let frameLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        frameLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(frameLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @MainActor
    func reload() {
        guard let sheet = stateMachine?.config.sprite.flatMap({ URL(string: $0.sheet) }) else { return }
        rows = SpriteSheetCache.rows(for: sheet)
        placement = nil
        show(row: stateMachine?.currentSpriteRow, node: stateMachine?.currentNodeId)
    }

    @MainActor
    func show(row newRow: Int?, node newNode: String?) {
        guard newRow != row || newNode != node else { return }
        row = newRow
        node = newNode
        frames = newRow.flatMap { rows[$0] } ?? []
        index = 0
        restartTimer()
    }

    override func layout() {
        super.layout()
        placement = nil
        draw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        placement = nil
        draw()
    }

    @MainActor
    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        draw()
        guard let machine = stateMachine, let node, !frames.isEmpty else { return }
        let fps = SpriteTiming.fps(for: node, in: machine.config)
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.advance() }
        }
        // .common so the pet keeps animating during menu/scroll tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor
    func advance() {
        guard !frames.isEmpty else { return }
        index += 1
        if index >= frames.count {
            // End of one pass: the state machine may switch state or re-pick the row.
            index = 0
            stateMachine?.handleLoopCycleCompleted()
            if let machine = stateMachine, machine.currentSpriteRow != row || machine.currentNodeId != node {
                show(row: machine.currentSpriteRow, node: machine.currentNodeId)
                return
            }
        }
        draw()
    }

    private func draw() {
        guard !frames.isEmpty, bounds.width > 0 else { frameLayer.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        if placement == nil {
            let sizes = rows.values.joined().map { CGSize(width: $0.width, height: $0.height) }
            placement = SpriteLayout(frameSizes: sizes, canvas: CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
        let frame = frames[index % frames.count]
        guard let placement else { return }
        let rect = placement.rect(for: CGSize(width: frame.width, height: frame.height))
        let filter: CALayerContentsFilter = placement.isWholeScale ? .nearest : .linear
        frameLayer.magnificationFilter = filter
        frameLayer.minificationFilter = filter
        frameLayer.contentsScale = scale
        // Layout is top-left; the layer origin is bottom-left.
        frameLayer.frame = CGRect(x: rect.minX / scale, y: (bounds.height * scale - rect.maxY) / scale,
                                  width: rect.width / scale, height: rect.height / scale)
        frameLayer.contents = frame
    }

    /// Stops the frame timer when SwiftUI removes the view.
    func teardown() {
        timer?.invalidate()
        timer = nil
    }
}
