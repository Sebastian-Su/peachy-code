import XCTest
@testable import PeachyPet

/// Runs the real publish script against a library in a temporary HOME, then installs
/// the pack it makes with the resource center's installer.
final class SpritePetPublishTests: XCTestCase {
    private var tmp: URL!
    private var home: URL { tmp.appendingPathComponent("home") }
    private var support: URL { home.appendingPathComponent("Library/Application Support/PeachyPet") }
    private var script: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/publish-pet.sh") }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spritepub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func importedPet(source: SpritePetSource) throws -> SpritePetInstaller.Installed {
        let pack = tmp.appendingPathComponent("pack-\(source.rawValue)")
        try writeSpritePack(in: pack)
        return try SpritePetInstaller.install(directory: pack, source: source, into: support.appendingPathComponent("Pets"))
    }

    private func writeLibrary(_ pets: [SpritePetInstaller.Installed]) throws {
        let mascots = pets.map { SavedMascot(id: UUID(), name: $0.config.name, config: $0.config, addedAt: Date(), templateSlug: $0.slug) }
        try JSONEncoder().encode(mascots).write(to: support.appendingPathComponent("mascots.json"))
    }

    /// Returns (exit status, zip path).
    private func publish(_ name: String, packId: String) throws -> (Int32, URL) {
        let out = tmp.appendingPathComponent("out")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, name, packId, "--out", out.path]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, out.appendingPathComponent("\(packId).zip"))
    }

    // S27: a locally imported sprite pet round-trips through publish and the resource center installer
    @MainActor
    func testLocalSpritePetPublishesAndInstallsBack() throws {
        try writeLibrary([try importedPet(source: .local)])
        let (status, zip) = try publish("Boba", packId: "boba-pack")
        XCTAssertEqual(status, 0)
        let sha = try XCTUnwrap(MascotProjectStore.sha256(fileAt: zip))
        let dest = tmp.appendingPathComponent("installed/boba-pack")
        let config = try PetPackInstaller.install(archive: zip, expectedSHA256: sha, into: dest)

        let sprite = try XCTUnwrap(config.sprite)
        let sheet = try XCTUnwrap(URL(string: sprite.sheet))
        XCTAssertTrue(sheet.path.hasPrefix(dest.path), "sheet points into the installed pack")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheet.path))
        let poster = try XCTUnwrap(config.nodes.first?.transparentThumbnailUrl.flatMap(URL.init(string:)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: poster.path))
        XCTAssertEqual(Set(sprite.rows.values), [[0], [7, 1, 2], [6], [8]])

        let machine = OverlayStateMachine(config: config)
        machine.start()
        XCTAssertEqual(machine.currentSpriteRow, 0, "plays like any sprite pet")
    }

    // N3: pets downloaded from OpenPets or Petdex cannot be published
    func testDownloadedSpritePetsAreRefused() throws {
        for source in [SpritePetSource.openpets, .petdex] {
            try writeLibrary([try importedPet(source: source)])
            let (status, zip) = try publish("Boba", packId: "boba-\(source.rawValue)")
            XCTAssertNotEqual(status, 0, "\(source) must be refused")
            XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path), "no pack for \(source)")
        }
    }

    // S28: deleting the resource-center copy never removes the local import with the same id
    func testDeletingPublishedCopyKeepsTheLocalImport() throws {
        let local = try importedPet(source: .local)
        try writeLibrary([local])
        let (_, zip) = try publish("Boba", packId: "boba-pack")
        let petsRoot = support.appendingPathComponent("Pets")
        let config = try PetPackInstaller.install(archive: zip, expectedSHA256: try XCTUnwrap(MascotProjectStore.sha256(fileAt: zip)),
                                                  into: petsRoot.appendingPathComponent("boba-pack"))
        let store = MascotStore()
        store.addOrReplacePack(config: config, packId: "boba-pack")
        store.delete(id: try XCTUnwrap(store.mascots.first { $0.templateSlug == "pack:boba-pack" }?.id), petsRoot: petsRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.directory.path), "local import untouched")
    }
}
