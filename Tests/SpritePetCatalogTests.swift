import XCTest
@testable import PeachyPet

/// Fixtures are small slices of the real catalogs (2026-11-09), read from disk so the
/// tests never touch the network.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sprite-catalogs")
private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

/// Answers requests from fixtures, records every URL asked for, and can fail one host.
final class FakeCatalogTransport: SpriteCatalogTransport, @unchecked Sendable {
    var failingHost: String?
    private(set) var requested: [URL] = []
    private let lock = NSLock()

    func data(from url: URL) async throws -> Data {
        lock.withLock { requested.append(url) }
        if url.host == failingHost { throw URLError(.timedOut) }
        switch url.lastPathComponent {
        case "petdex-v1.json", "manifest": return try fixture("petdex-manifest.json")
        case "catalog.v3.json": return try fixture("openpets-index.json")
        case "page-000.json": return try fixture("openpets-page-000.json")
        case "page-001.json": return try fixture("openpets-page-001.json")
        default: throw URLError(.fileDoesNotExist)
        }
    }
}

final class SpritePetCatalogTests: XCTestCase {
    private var cacheDir: URL!

    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("spritecat-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: cacheDir) }

    // S8, S11 (decode): petdex entries carry name, author, kind and sheet; a broken one is skipped (N5)
    func testPetdexManifestDecodes() throws {
        let pets = try SpriteCatalog.decodePetdex(fixture("petdex-manifest.json"))
        XCTAssertEqual(pets.count, 6, "the broken entry is dropped, the rest stay")
        let momo = try XCTUnwrap(pets.first { $0.id == "momo" })
        XCTAssertEqual(momo.source, .petdex)
        XCTAssertNotNil(momo.author)
        XCTAssertNil(momo.thumbnail, "petdex has no thumbnails")
        XCTAssertEqual(momo.sheet.host, "assets.petdex.dev")
        XCTAssertEqual(Set(pets.compactMap(\.kind)), ["character", "creature", "object"])
    }

    // S9: openpets entries carry a thumbnail
    func testOpenpetsPagesDecode() throws {
        let pets = try SpriteCatalog.decodeOpenpetsPage(fixture("openpets-page-000.json"))
        XCTAssertEqual(pets.count, 4, "the broken entry is dropped")
        XCTAssertTrue(pets.allSatisfy { $0.source == .openpets && $0.thumbnail != nil })
    }

    // S6, S8: each source loads separately; openpets follows its page list
    func testLoadsBothSourcesAndAllOpenpetsPages() async throws {
        let transport = FakeCatalogTransport()
        let catalog = SpriteCatalog(transport: transport, cacheDirectory: cacheDir)
        let openpets = try await catalog.load(.openpets)
        let petdex = try await catalog.load(.petdex)
        XCTAssertEqual(openpets.count, 6)
        XCTAssertEqual(petdex.count, 6)
    }

    // S10, S12, N3: opening a tab asks for catalog files only, never a spritesheet or thumbnail
    func testOpeningTabsRequestsNoImages() async throws {
        let transport = FakeCatalogTransport()
        let catalog = SpriteCatalog(transport: transport, cacheDirectory: cacheDir)
        _ = try await catalog.load(.openpets)
        _ = try await catalog.load(.petdex)
        XCTAssertTrue(transport.requested.allSatisfy { $0.pathExtension == "json" || $0.lastPathComponent == "manifest" },
                      "\(transport.requested)")
        XCTAssertFalse(transport.requested.contains { ["webp", "png"].contains($0.pathExtension) })
    }

    // S12: one source failing leaves the other working
    func testOneSourceFailingDoesNotAffectTheOther() async throws {
        let transport = FakeCatalogTransport()
        transport.failingHost = "petdex.dev"
        let catalog = SpriteCatalog(transport: transport, cacheDirectory: cacheDir)
        let openpets = try await catalog.load(.openpets)
        XCTAssertEqual(openpets.count, 6)
        do {
            _ = try await catalog.load(.petdex)
            XCTFail("petdex should report it cannot be reached")
        } catch {}
    }

    // S13: a cached list is available without the network
    func testCachedListLoadsWithoutNetwork() async throws {
        let online = SpriteCatalog(transport: FakeCatalogTransport(), cacheDirectory: cacheDir)
        _ = try await online.load(.petdex)
        let offline = FakeCatalogTransport()
        offline.failingHost = "petdex.dev"
        let catalog = SpriteCatalog(transport: offline, cacheDirectory: cacheDir)
        let cached = try XCTUnwrap(catalog.cached(.petdex))
        XCTAssertEqual(cached.count, 6)
        XCTAssertTrue(offline.requested.isEmpty)
    }

    // S8: search by name, filter petdex by kind
    func testSearchAndKindFilter() throws {
        let pets = try SpriteCatalog.decodePetdex(fixture("petdex-manifest.json"))
        XCTAssertEqual(SpriteCatalog.filter(pets, query: "MOMO", kind: nil).map(\.id), ["momo"])
        XCTAssertEqual(SpriteCatalog.filter(pets, query: "", kind: "object").count, pets.filter { $0.kind == "object" }.count)
        XCTAssertEqual(SpriteCatalog.filter(pets, query: "", kind: nil).count, 6)
        XCTAssertTrue(SpriteCatalog.filter(pets, query: "zzzz-none", kind: nil).isEmpty)
    }

    // S14, S15: same id on both sites stays two different pets; fan art is listed as is
    func testSameIdOnBothSitesIsTwoPets() throws {
        let petdex = try SpriteCatalog.decodePetdex(fixture("petdex-manifest.json"))
        let openpets = try SpriteCatalog.decodeOpenpetsPage(fixture("openpets-page-000.json"))
        let a = try XCTUnwrap(petdex.first { $0.id == "momo" }), b = try XCTUnwrap(openpets.first { $0.id == "momo" })
        XCTAssertNotEqual(a.slug, b.slug)
        XCTAssertNotNil(petdex.first { $0.id == "homelander" }, "fan art stays in the list")
    }
}

/// Serves a real spritesheet for any image URL and a pet.json for petdex manifests.
final class FakeDownloadTransport: SpriteCatalogTransport, @unchecked Sendable {
    private(set) var requested: [URL] = []
    private let lock = NSLock()
    let sheet: Data

    init() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-\(UUID().uuidString).png")
        try writeSpriteSheet(frames: [6, 8, 8, 4, 5, 8, 6, 6, 6], to: file)
        sheet = try Data(contentsOf: file)
        try? FileManager.default.removeItem(at: file)
    }

    func data(from url: URL) async throws -> Data {
        lock.withLock { requested.append(url) }
        if url.lastPathComponent == "petjson.json" {
            return try JSONSerialization.data(withJSONObject: ["id": "momo", "displayName": "Momo from petdex", "description": "d", "spritesheetPath": "spritesheet.webp"])
        }
        return sheet
    }
}

final class SpritePetDownloadTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spritedl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func pets() throws -> (petdex: SpriteCatalogPet, openpets: SpriteCatalogPet) {
        let petdex = try SpriteCatalog.decodePetdex(fixture("petdex-manifest.json"))
        let openpets = try SpriteCatalog.decodeOpenpetsPage(fixture("openpets-page-000.json"))
        return (try XCTUnwrap(petdex.first { $0.id == "momo" }), try XCTUnwrap(openpets.first { $0.id == "momo" }))
    }

    // S2, S11, S14: the same id from both sites installs as two pets, each marked with its source
    func testDownloadingMomoFromBothSitesGivesTwoPets() async throws {
        let transport = try FakeDownloadTransport()
        let downloader = SpritePetDownloader(transport: transport, petsRoot: tmp.appendingPathComponent("Pets"), workDirectory: tmp)
        let (a, b) = try pets()
        let fromPetdex = try await downloader.install(a)
        let fromOpenpets = try await downloader.install(b)
        XCTAssertEqual(fromPetdex.slug, "sprite:petdex:momo")
        XCTAssertEqual(fromOpenpets.slug, "sprite:openpets:momo")
        XCTAssertEqual(fromPetdex.config.sprite?.source, .petdex)
        XCTAssertEqual(fromOpenpets.config.sprite?.source, .openpets)
        XCTAssertEqual(fromPetdex.config.name, "Momo from petdex", "petdex name comes from its pet.json")
        XCTAssertNotEqual(fromPetdex.directory, fromOpenpets.directory)

        let store = MascotStore()
        store.addOrReplaceSprite(config: fromPetdex.config, slug: fromPetdex.slug)
        store.addOrReplaceSprite(config: fromOpenpets.config, slug: fromOpenpets.slug)
        let installed = store.installedSpriteSlugs
        XCTAssertTrue(installed.contains(a.slug) && installed.contains(b.slug))
        [a.slug, b.slug].forEach { slug in store.mascots.filter { $0.templateSlug == slug }.forEach { store.remove(id: $0.id) } }
    }

    // S14: installing on one site doesn't mark the other site's pet as installed
    func testInstalledIsPerSource() async throws {
        let transport = try FakeDownloadTransport()
        let downloader = SpritePetDownloader(transport: transport, petsRoot: tmp.appendingPathComponent("Pets"), workDirectory: tmp)
        let (a, b) = try pets()
        let pet = try await downloader.install(a)
        let store = MascotStore()
        store.addOrReplaceSprite(config: pet.config, slug: pet.slug)
        XCTAssertTrue(store.installedSpriteSlugs.contains(a.slug))
        XCTAssertFalse(store.installedSpriteSlugs.contains(b.slug))
        store.mascots.filter { $0.templateSlug == a.slug }.forEach { store.remove(id: $0.id) }
    }

    // N3: only the pet that was clicked is downloaded
    func testOnlyTheClickedPetIsRequested() async throws {
        let transport = try FakeDownloadTransport()
        let downloader = SpritePetDownloader(transport: transport, petsRoot: tmp.appendingPathComponent("Pets"), workDirectory: tmp)
        let (a, _) = try pets()
        _ = try await downloader.install(a)
        XCTAssertEqual(Set(transport.requested), Set([a.sheet, try XCTUnwrap(a.manifest)]))
    }

    // N4 over the network: a manifest whose sheet path climbs out is still rejected, nothing left behind
    func testDownloadedManifestCannotEscape() async throws {
        final class Evil: SpriteCatalogTransport, @unchecked Sendable {
            func data(from url: URL) async throws -> Data {
                try JSONSerialization.data(withJSONObject: ["id": "momo", "displayName": "x", "spritesheetPath": "../../x.webp"])
            }
        }
        let root = tmp.appendingPathComponent("Pets")
        let downloader = SpritePetDownloader(transport: Evil(), petsRoot: root, workDirectory: tmp)
        let (a, _) = try pets()
        do { _ = try await downloader.install(a); XCTFail("should be rejected") } catch {}
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.filter { !$0.hasPrefix(".") } ?? [], [])
    }
}

final class SpritePreviewCacheTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spriteprev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func momo() throws -> SpriteCatalogPet {
        try XCTUnwrap(SpriteCatalog.decodePetdex(fixture("petdex-manifest.json")).first { $0.id == "momo" })
    }

    // S10: preview downloads just this sheet and gives back the first idle frame
    func testPreviewFetchesOneSheetAndReturnsIdleFrame() async throws {
        let transport = try FakeDownloadTransport()
        let cache = SpritePreviewCache(directory: tmp.appendingPathComponent("previews"), transport: transport)
        let pet = try momo()
        let frame = try await cache.preview(pet)
        XCTAssertEqual(frame.width, 20)
        XCTAssertEqual(frame.height, 22)
        XCTAssertEqual(transport.requested, [pet.sheet])
    }

    // S11: downloading after a preview reuses the cached sheet
    func testDownloadAfterPreviewDoesNotFetchTheSheetAgain() async throws {
        let transport = try FakeDownloadTransport()
        let cache = SpritePreviewCache(directory: tmp.appendingPathComponent("previews"), transport: transport)
        let pet = try momo()
        _ = try await cache.preview(pet)
        let downloader = SpritePetDownloader(transport: transport, petsRoot: tmp.appendingPathComponent("Pets"), workDirectory: tmp)
        _ = try await downloader.install(pet, sheetData: cache.cachedSheet(pet))
        XCTAssertEqual(transport.requested.filter { $0 == pet.sheet }.count, 1)
    }

    // S10: a preview survives closing and reopening (new cache instance, same folder)
    func testPreviewIsKeptOnDisk() async throws {
        let transport = try FakeDownloadTransport()
        let dir = tmp.appendingPathComponent("previews")
        let pet = try momo()
        _ = try await SpritePreviewCache(directory: dir, transport: transport).preview(pet)
        let reopened = SpritePreviewCache(directory: dir, transport: transport)
        XCTAssertNotNil(reopened.cachedFrame(pet))
        _ = try await reopened.preview(pet)
        XCTAssertEqual(transport.requested.count, 1)
    }

    // S24: over the limit, the least recently used sheets go first
    func testCacheEvictsLeastRecentlyUsedOverTheLimit() throws {
        let dir = tmp.appendingPathComponent("previews")
        let cache = SpritePreviewCache(directory: dir, transport: try FakeDownloadTransport(), limitBytes: 250)
        let blob = Data(repeating: 1, count: 100)
        try cache.store(blob, key: "a")
        try cache.store(blob, key: "b")
        _ = cache.data(key: "a") // a is now newer than b
        try cache.store(blob, key: "c")
        XCTAssertNotNil(cache.data(key: "a"))
        XCTAssertNil(cache.data(key: "b"), "least recently used goes first")
        XCTAssertNotNil(cache.data(key: "c"))
        XCTAssertLessThanOrEqual(cache.totalBytes, 250)
    }

    func testDefaultLimitIs200MB() {
        XCTAssertEqual(SpritePreviewCache.defaultLimitBytes, 200 * 1024 * 1024)
    }
}
