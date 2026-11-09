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
