import XCTest
import AppKit
@testable import PeachyPet

/// Writes a PNG sheet on the standard 8 x 9 grid with `frames[row]` filled cells per row.
func writeSpriteSheet(frames: [Int], to url: URL) throws {
    let cellW = 24, cellH = 26
    let w = cellW * 8, h = cellH * 9
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    for (row, count) in frames.enumerated() {
        for col in 0..<count {
            ctx.fill(CGRect(x: col * cellW + 2, y: h - (row + 1) * cellH + 2, width: cellW - 4, height: cellH - 4))
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeSpritePack(id: String = "boba", name: String = "Boba", description: String? = "An otter",
                     sheetPath: String = "spritesheet.png", frames: [Int] = [6, 8, 8, 4, 5, 8, 6, 6, 6], in dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var manifest: [String: Any] = ["id": id, "displayName": name, "spritesheetPath": sheetPath]
    if let description { manifest["description"] = description }
    try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("pet.json"))
    if !sheetPath.contains("..") { try writeSpriteSheet(frames: frames, to: dir.appendingPathComponent(sheetPath)) }
}

final class SpritePetInstallTests: XCTestCase {
    private var tmp: URL!
    private var root: URL { tmp.appendingPathComponent("Pets") }
    private var pack: URL { tmp.appendingPathComponent("source-pack") }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spritepet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // S1
    func testImportedPetUsesTheExistingRecordShapeWithSpriteInfo() throws {
        try writeSpritePack(in: pack)
        let pet = try SpritePetInstaller.install(directory: pack, source: .local, into: root)
        XCTAssertEqual(pet.config.name, "Boba")
        XCTAssertEqual(pet.config.nodes.map(\.name), ["Idle", "Working", "Needs Attention", "Thinking"])
        XCTAssertEqual(pet.config.edges.count, 16)
        XCTAssertEqual(pet.config.edges.filter { !$0.isLoop && !($0.conditions ?? []).isEmpty }.count, 12)
        XCTAssertTrue(pet.config.edges.allSatisfy { $0.videos.hevc == nil && $0.videos.webm == nil })
        let sprite = try XCTUnwrap(pet.config.sprite)
        XCTAssertEqual(sprite.source, .local)
        XCTAssertEqual(sprite.description, "An otter")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(URL(string: sprite.sheet)).path))
    }

    // S2 (local part)
    func testIdentityCombinesSourceAndId() throws {
        try writeSpritePack(in: pack)
        let pet = try SpritePetInstaller.install(directory: pack, source: .local, into: root)
        XCTAssertEqual(pet.slug, "sprite:local:boba")
        XCTAssertTrue(pet.directory.path.hasSuffix("/Pets/sprites/local/boba"))
    }

    // S16 mapping, stored at import
    func testStatesMapToSheetRows() throws {
        try writeSpritePack(in: pack)
        let config = try SpritePetInstaller.install(directory: pack, source: .local, into: root).config
        let rows = try XCTUnwrap(config.sprite).rows
        func rowsFor(_ name: String) -> [Int]? { rows[try! XCTUnwrap(config.nodes.first { $0.name == name }).id] }
        XCTAssertEqual(rowsFor("Idle"), [0])
        XCTAssertEqual(rowsFor("Working"), [7, 1, 2])
        XCTAssertEqual(rowsFor("Needs Attention"), [6])
        XCTAssertEqual(rowsFor("Thinking"), [8])
    }

    // S3
    func testImportingTheSamePetTwiceReplacesIt() throws {
        try writeSpritePack(name: "Old", in: pack)
        let first = try SpritePetInstaller.install(directory: pack, source: .local, into: root)
        try writeSpritePack(name: "New", in: pack)
        let second = try SpritePetInstaller.install(directory: pack, source: .local, into: root)
        XCTAssertEqual(first.slug, second.slug)

        let store = MascotStore()
        let before = store.mascots.count
        store.addOrReplaceSprite(config: first.config, slug: first.slug)
        store.addOrReplaceSprite(config: second.config, slug: second.slug)
        XCTAssertEqual(store.mascots.count, before + 1)
        XCTAssertEqual(store.mascots.first { $0.templateSlug == first.slug }?.name, "New")
        store.mascots.filter { $0.templateSlug == first.slug }.forEach { store.remove(id: $0.id) }
    }

    // S22
    func testPosterIsTheFirstIdleFrame() throws {
        try writeSpritePack(in: pack)
        let config = try SpritePetInstaller.install(directory: pack, source: .local, into: root).config
        guard case .image(let url)? = MascotPoster.source(for: config) else { return XCTFail("no poster") }
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(image.representations.first?.pixelsWide, 20)
        XCTAssertEqual(image.representations.first?.pixelsHigh, 22)
    }

    // S5, on the real pack when this machine has it
    func testBobaSlicesIntoTheExpectedRows() throws {
        let sheet = URL(fileURLWithPath: NSHomeDirectory() + "/.agentpet/pets/boba/spritesheet.webp")
        guard let image = NSImage(contentsOf: sheet) else { throw XCTSkip("boba is not on this machine") }
        var rect = CGRect(origin: .zero, size: image.size)
        let clips = SpriteSlicer.slice(try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        XCTAssertEqual(clips.map(\.count), [6, 8, 8, 4, 5, 8, 6, 6, 6])
        XCTAssertTrue(clips.joined().allSatisfy { $0.height == 198 })
    }

    // S5, S18: a blank row keeps the rows after it in place
    func testBlankRowOnStandardGridDoesNotShiftLaterRows() throws {
        try writeSpritePack(frames: [6, 8, 8, 4, 5, 8, 0, 6, 6], in: pack)
        let config = try SpritePetInstaller.install(directory: pack, source: .local, into: root).config
        let rows = try XCTUnwrap(config.sprite).rows
        XCTAssertEqual(rows[try XCTUnwrap(config.nodes.first { $0.name == "Thinking" }).id], [8])
        XCTAssertEqual(rows[try XCTUnwrap(config.nodes.first { $0.name == "Needs Attention" }).id], [0], "missing row falls back to idle")
    }

    // N1: a build that only knows video pets must still read the whole library
    func testLibraryWithSpritePetStillDecodesWithTheOldShape() throws {
        struct OldVideos: Decodable { let webm: String?; let hevc: String? }
        struct OldEdge: Decodable { let id, source, target: String; let isLoop: Bool; let duration: Double; let videos: OldVideos }
        struct OldNode: Decodable { let id, name: String; let transparentThumbnailUrl: String? }
        struct OldConfig: Decodable { let version, name, initialNode: String; let autoPlay: Bool; let nodes: [OldNode]; let edges: [OldEdge] }
        struct OldMascot: Decodable { let id: UUID; let name: String; let config: OldConfig; let addedAt: Date; let templateSlug: String? }

        try writeSpritePack(in: pack)
        let pet = try SpritePetInstaller.install(directory: pack, source: .local, into: root)
        let videoJSON = #"{"version":"2.0","name":"Video","initialNode":"idle","autoPlay":true,"nodes":[{"id":"idle","name":"Idle"}],"edges":[]}"#
        let library = [
            SavedMascot(id: UUID(), name: pet.config.name, config: pet.config, addedAt: Date(), templateSlug: pet.slug),
            SavedMascot(id: UUID(), name: "Video", config: try JSONDecoder().decode(PeachyAnimationConfig.self, from: Data(videoJSON.utf8)), addedAt: Date(), templateSlug: nil),
        ]
        let decoded = try JSONDecoder().decode([OldMascot].self, from: JSONEncoder().encode(library))
        XCTAssertEqual(decoded.map(\.name), ["Boba", "Video"])
    }

    // N2
    func testFailedImportLeavesInstalledPetsUntouched() throws {
        let video = root.appendingPathComponent("gothic-maid")
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: video.appendingPathComponent("idle.mov"))
        try writeSpritePack(in: pack)
        _ = try SpritePetInstaller.install(directory: pack, source: .local, into: root)
        let before = listing(root)

        try writeSpritePack(frames: [], in: pack)
        XCTAssertThrowsError(try SpritePetInstaller.install(directory: pack, source: .local, into: root))
        XCTAssertEqual(listing(root), before)
    }

    // N4
    func testSheetPathEscapingThePackIsRejected() throws {
        try writeSpritePack(sheetPath: "../../etc/passwd", in: pack)
        XCTAssertThrowsError(try SpritePetInstaller.install(directory: pack, source: .local, into: root)) {
            XCTAssertEqual($0 as? PetPackError, .unsafePath("../../etc/passwd"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path) && !listing(root).isEmpty)
    }

    // N4: the id becomes a folder name
    func testPetIdThatIsAPathIsRejected() throws {
        for id in ["../../evil", "a/b", "..", ""] {
            try writeSpritePack(id: id, in: pack)
            XCTAssertThrowsError(try SpritePetInstaller.install(directory: pack, source: .local, into: root), id)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("evil").path))
    }

    // N5
    func testBrokenPacksFailWithoutCrashing() throws {
        try writeSpritePack(frames: [], in: pack)   // fully transparent
        XCTAssertThrowsError(try SpritePetInstaller.install(directory: pack, source: .local, into: root))
        try Data("not an image".utf8).write(to: pack.appendingPathComponent("spritesheet.png"))
        XCTAssertThrowsError(try SpritePetInstaller.install(directory: pack, source: .local, into: root))
        try Data("{oops".utf8).write(to: pack.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try SpritePetInstaller.install(directory: pack, source: .local, into: root))
    }

    // S18: a one-row picture plays that row everywhere
    func testSingleRowSheetUsesThatRowForEveryState() throws {
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 100, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 2, width: 40, height: 26)); ctx.fill(CGRect(x: 50, y: 2, width: 40, height: 26))
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: pack.appendingPathComponent("spritesheet.png"))
        try JSONSerialization.data(withJSONObject: ["id": "one", "displayName": "One", "spritesheetPath": "spritesheet.png"]).write(to: pack.appendingPathComponent("pet.json"))
        let sprite = try XCTUnwrap(SpritePetInstaller.install(directory: pack, source: .local, into: root).config.sprite)
        XCTAssertEqual(Set(sprite.rows.values), [[0]])
    }
}

final class SpritePetDeleteTests: XCTestCase {
    // S23 + N2: deleting a sprite pet removes its folder and nothing else
    func testDeletingSpritePetRemovesItsFilesOnly() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spritedel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Pets")
        let video = root.appendingPathComponent("gothic-maid")
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: video.appendingPathComponent("idle.mov"))
        try writeSpritePack(in: tmp.appendingPathComponent("pack"))
        let pet = try SpritePetInstaller.install(directory: tmp.appendingPathComponent("pack"), source: .local, into: root)
        let store = MascotStore()
        store.addOrReplaceSprite(config: pet.config, slug: pet.slug)
        let id = try XCTUnwrap(store.mascots.first { $0.templateSlug == pet.slug }?.id)
        let videoFiles = try FileManager.default.subpathsOfDirectory(atPath: video.path)

        store.delete(id: id, petsRoot: root)

        XCTAssertNil(store.mascots.first { $0.id == id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: pet.directory.path))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: video.path), videoFiles)
    }

    // Video pets keep today's behaviour: removed from the library, files left alone
    func testDeletingVideoPetKeepsItsFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("videodel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Pets")
        let dir = root.appendingPathComponent("tester")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: dir.appendingPathComponent("idle.mov"))
        let json = #"{"version":"2.0","name":"Tester","initialNode":"idle","autoPlay":true,"nodes":[{"id":"idle","name":"Idle"}],"edges":[]}"#
        let store = MascotStore()
        store.addOrReplacePack(config: try JSONDecoder().decode(PeachyAnimationConfig.self, from: Data(json.utf8)), packId: "tester")
        let id = try XCTUnwrap(store.mascots.first { $0.templateSlug == "pack:tester" }?.id)
        store.delete(id: id, petsRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("idle.mov").path))
    }

    // N2: a tampered record cannot point the delete outside the sprite folder
    func testDeleteNeverLeavesTheSpriteFolder() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spriteesc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Pets")
        let victim = root.appendingPathComponent("gothic-maid")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try writeSpritePack(in: tmp.appendingPathComponent("pack"))
        var config = try SpritePetInstaller.install(directory: tmp.appendingPathComponent("pack"), source: .local, into: root).config
        config.sprite = SpriteInfo(source: .local, id: "../../gothic-maid", description: nil, sheet: "", rows: [:])
        let store = MascotStore()
        store.addOrReplaceSprite(config: config, slug: "sprite:local:evil")
        store.delete(id: try XCTUnwrap(store.mascots.first { $0.templateSlug == "sprite:local:evil" }?.id), petsRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }
}
