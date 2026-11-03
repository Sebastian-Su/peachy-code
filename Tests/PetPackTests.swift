import XCTest
@testable import PeachyPet

final class PetPackTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("petpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private let petJSON = #"""
    {"version":"2.0","name":"Tester","initialNode":"idle","autoPlay":true,
     "nodes":[{"id":"idle","name":"Idle","transparentThumbnailUrl":"poster.png"}],
     "edges":[{"id":"e","source":"idle","target":"idle","isLoop":true,"duration":1,"videos":{"hevc":"videos/idle.mov"}}]}
    """#

    /// Builds a pack zip the way the publish script does: pet.json + media, zipped with ditto.
    private func makePack(json: String? = nil, extraPath: String? = nil) throws -> URL {
        let src = tmp.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("videos"), withIntermediateDirectories: true)
        try Data((json ?? petJSON).utf8).write(to: src.appendingPathComponent("pet.json"))
        try Data("video".utf8).write(to: src.appendingPathComponent("videos/idle.mov"))
        try Data("png".utf8).write(to: src.appendingPathComponent("poster.png"))
        let zip = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", src.path, zip.path]
        try p.run(); p.waitUntilExit()
        return zip
    }

    func testCatalogDecodes() throws {
        let json = #"{"schemaVersion":1,"pets":[{"id":"peachmilky","name":"PeachMilky","version":"1","preview":"https://x/p.png","download":"https://x/p.zip","sha256":"ab","size":10}]}"#
        let catalog = try JSONDecoder().decode(PetCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.pets.map(\.id), ["peachmilky"])
        XCTAssertEqual(catalog.pets[0].download.absoluteString, "https://x/p.zip")
    }

    func testInstallVerifiesAndPointsMediaAtInstalledFiles() throws {
        let zip = try makePack()
        let sha = try XCTUnwrap(MascotProjectStore.sha256(fileAt: zip))
        let dest = tmp.appendingPathComponent("installed")

        let config = try PetPackInstaller.install(archive: zip, expectedSHA256: sha, into: dest)

        XCTAssertEqual(config.name, "Tester")
        let video = try XCTUnwrap(config.edges.first?.videos.hevc.flatMap(URL.init(string:)))
        XCTAssertTrue(video.isFileURL)
        XCTAssertEqual(try Data(contentsOf: video), Data("video".utf8))
        XCTAssertEqual(config.nodes.first?.transparentThumbnailUrl.flatMap(URL.init(string:))?.isFileURL, true)
    }

    func testChecksumMismatchIsRejectedAndNothingIsInstalled() throws {
        let zip = try makePack()
        let dest = tmp.appendingPathComponent("installed")
        XCTAssertThrowsError(try PetPackInstaller.install(archive: zip, expectedSHA256: String(repeating: "0", count: 64), into: dest)) {
            XCTAssertEqual($0 as? PetPackError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testMediaPathEscapingThePackIsRejected() throws {
        let evil = petJSON.replacingOccurrences(of: "videos/idle.mov", with: "../../etc/passwd")
        let zip = try makePack(json: evil)
        let sha = try XCTUnwrap(MascotProjectStore.sha256(fileAt: zip))
        XCTAssertThrowsError(try PetPackInstaller.install(archive: zip, expectedSHA256: sha, into: tmp.appendingPathComponent("installed"))) {
            XCTAssertEqual($0 as? PetPackError, .unsafePath("../../etc/passwd"))
        }
    }
}

final class PetCatalogInstallTests: XCTestCase {
    /// Installing a pack twice replaces the earlier copy instead of piling up duplicates.
    func testInstallingSamePackAgainReplacesIt() {
        let json = #"{"version":"2.0","name":"Tester","initialNode":"idle","autoPlay":true,"nodes":[{"id":"idle","name":"Idle"}],"edges":[]}"#
        let config = try! JSONDecoder().decode(PeachyAnimationConfig.self, from: Data(json.utf8))
        let store = MascotStore()
        let before = store.mascots.count
        store.addOrReplacePack(config: config, packId: "tester")
        store.addOrReplacePack(config: config, packId: "tester")
        XCTAssertEqual(store.mascots.count, before + 1)
        XCTAssertEqual(store.mascots.first?.templateSlug, "pack:tester")
        store.mascots.filter { $0.templateSlug == "pack:tester" }.forEach { store.remove(id: $0.id) }
    }
}
