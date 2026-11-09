import AppKit

/// Installs a spritesheet pet pack (`pet.json` plus one sheet image, the format
/// petdex and openpets use) as an ordinary 4-state mascot record: the usual
/// nodes and edges with no videos, plus `sprite` saying which sheet rows each
/// state plays. Older builds ignore `sprite`, so a library holding sprite pets
/// still decodes there.
enum SpritePetInstaller {
    struct Installed {
        let config: PeachyAnimationConfig
        /// `sprite:<source>:<id>`, the mascot's `templateSlug`.
        let slug: String
        let directory: URL
    }

    private struct Manifest: Decodable {
        let id: String
        let displayName: String
        let description: String?
        let spritesheetPath: String
    }

    /// Sheet rows of the standard layout.
    enum SheetRow {
        static let idle = 0, runRight = 1, runLeft = 2, waiting = 6, running = 7, review = 8
    }

    /// PeachyPet state -> sheet rows. Working picks one of its rows at random each loop.
    static let stateRows: [(state: String, name: String, rows: [Int])] = [
        ("idle", "Idle", [SheetRow.idle]),
        ("working", "Working", [SheetRow.running, SheetRow.runRight, SheetRow.runLeft]),
        ("needs-attention", "Needs Attention", [SheetRow.waiting]),
        ("thinking", "Thinking", [SheetRow.review]),
    ]

    static func slug(source: SpritePetSource, id: String) -> String { "sprite:\(source.rawValue):\(id)" }

    static func directory(for source: SpritePetSource, id: String, under root: URL) -> URL {
        root.appendingPathComponent("sprites/\(source.rawValue)/\(id)", isDirectory: true)
    }

    /// Validates and slices the pack before touching `root`, then swaps it in whole.
    static func install(directory pack: URL, source: SpritePetSource, into root: URL) throws -> Installed {
        guard let data = try? Data(contentsOf: pack.appendingPathComponent("pet.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw PetPackError.invalidPack
        }
        guard isSafeId(manifest.id) else { throw PetPackError.unsafePath(manifest.id) }
        let sheet = try SafeFileTree.safeURL(relativePath: manifest.spritesheetPath, under: pack, resolveSymlinks: true,
                                             invalidPath: { PetPackError.unsafePath($0) })
        guard let image = NSImage(contentsOf: sheet) else { throw PetPackError.invalidPack }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw PetPackError.invalidPack }
        let rows = SpriteSlicer.rows(of: cgImage)
        guard let idleRow = resolvedRows([SheetRow.idle], available: rows).first,
              let posterFrame = rows[idleRow]?.first,
              let poster = NSBitmapImageRep(cgImage: posterFrame).representation(using: .png, properties: [:]) else {
            throw PetPackError.invalidPack
        }

        let fm = FileManager.default
        let destination = directory(for: source, id: manifest.id, under: root)
        let sheetName = "spritesheet." + (sheet.pathExtension.isEmpty ? "png" : sheet.pathExtension.lowercased())
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("pet.json"))
        try fm.copyItem(at: sheet, to: staging.appendingPathComponent(sheetName))
        try poster.write(to: staging.appendingPathComponent("poster.png"))

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)

        let config = makeConfig(manifest: manifest, source: source, rows: rows,
                                sheet: destination.appendingPathComponent(sheetName),
                                poster: destination.appendingPathComponent("poster.png"))
        return Installed(config: config, slug: slug(source: source, id: manifest.id), directory: destination)
    }

    /// Rows the sheet actually has; a state with none left plays the idle row (or the first row).
    static func resolvedRows(_ wanted: [Int], available: [Int: [CGImage]]) -> [Int] {
        let present = wanted.filter { available[$0] != nil }
        if !present.isEmpty { return present }
        if available[SheetRow.idle] != nil { return [SheetRow.idle] }
        return available.keys.min().map { [$0] } ?? []
    }

    private static func isSafeId(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil && !id.contains("..")
    }

    private static func makeConfig(manifest: Manifest, source: SpritePetSource, rows: [Int: [CGImage]],
                                   sheet: URL, poster: URL) -> PeachyAnimationConfig {
        let prefix = "\(source.rawValue)-\(manifest.id)"
        func node(_ state: String) -> String { "\(prefix)-\(state)" }
        let nodes = stateRows.map {
            PeachyAnimationNode(id: node($0.state), name: $0.name, transparentThumbnailUrl: poster.absoluteString)
        }
        // Same conditions as the bundled pets.
        let enter: [String: [(String, Bool)]] = [
            "idle": [("isIdle", true), ("isAlert", false), ("isCompacting", false)],
            "working": [("isWorking", true), ("isAlert", false), ("isCompacting", false)],
            "needs-attention": [("isAlert", true)],
            "thinking": [("isCompacting", true), ("isAlert", false)],
        ]
        let noVideo = PeachyAnimationVideos(webm: nil, hevc: nil)
        var edges = stateRows.map {
            PeachyAnimationEdge(id: "\(node($0.state))-loop", source: node($0.state), target: node($0.state), isLoop: true,
                                duration: 1, conditions: nil, videos: noVideo, priority: nil, speed: nil, sound: nil)
        }
        for from in stateRows {
            for to in stateRows where to.state != from.state {
                let conditions = enter[to.state]!.map {
                    PeachyAnimationCondition(input: OverlayStateMachine.agentPrefix + $0.0, value: .bool($0.1))
                }
                edges.append(PeachyAnimationEdge(id: "\(node(from.state))-\(to.state)", source: node(from.state), target: node(to.state),
                                                 isLoop: false, duration: 0, conditions: conditions, videos: noVideo,
                                                 priority: nil, speed: nil, sound: nil))
            }
        }
        let sprite = SpriteInfo(
            source: source,
            id: manifest.id,
            description: manifest.description,
            sheet: sheet.absoluteString,
            rows: Dictionary(uniqueKeysWithValues: stateRows.map { (node($0.state), resolvedRows($0.rows, available: rows)) })
        )
        return PeachyAnimationConfig(version: "2.0", name: manifest.displayName, initialNode: node("idle"), autoPlay: true,
                                     nodes: nodes, edges: edges, inputs: nil, sprite: sprite)
    }
}
