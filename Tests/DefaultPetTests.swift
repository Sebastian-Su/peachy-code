import XCTest
@testable import PeachyPet

final class DefaultPetTests: XCTestCase {
    private func config(_ name: String) -> PeachyAnimationConfig {
        try! JSONDecoder().decode(PeachyAnimationConfig.self, from: Data(
            #"{"version":"2.0","name":"\#(name)","initialNode":"i","autoPlay":true,"nodes":[{"id":"i","name":"Idle"}],"edges":[]}"#.utf8))
    }

    @MainActor
    func testStartupPrefersInstalledPeachMilkyOverClippy() {
        let clippy = SavedMascot(id: UUID(), name: "Clippy", config: config("Clippy"), addedAt: Date(), templateSlug: "clippy")
        let milky = SavedMascot(id: UUID(), name: "PeachMilky", config: config("PeachMilky"), addedAt: Date(),
                                templateSlug: DefaultPet.slug)
        XCTAssertEqual(OverlayManager.startupMascotConfig(from: [clippy, milky])?.name, "PeachMilky")
    }

    /// No network or a missing catalog entry must not break anything: the loader
    /// reports a retryable failure and leaves the pet library alone (S29).
    @MainActor
    func testUnreachableCatalogIsARetryableFailure() async {
        let store = MascotStore()
        let before = store.mascots.map(\.id)
        let loader = DefaultPetLoader(catalogURL: URL(string: "file:///nonexistent/catalog.json")!)

        let result = await loader.ensureInstalled(into: store)

        XCTAssertNil(result)
        guard case .failed = loader.state else { return XCTFail("expected failed, got \(loader.state)") }
        XCTAssertEqual(store.mascots.map(\.id), before)
    }

    @MainActor
    func testAlreadyInstalledPackNeedsNoDownload() async {
        let store = MascotStore()
        store.addOrReplacePack(config: config("PeachMilky"), packId: DefaultPet.packId)
        defer { store.mascots.filter { $0.templateSlug == DefaultPet.slug }.forEach { store.remove(id: $0.id) } }
        let loader = DefaultPetLoader(catalogURL: URL(string: "file:///nonexistent/catalog.json")!)

        let result = await loader.ensureInstalled(into: store)

        XCTAssertEqual(result?.name, "PeachMilky")
        XCTAssertEqual(loader.state, .ready)
    }

    func testPosterShipsWithTheApp() {
        let poster = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources/Images/\(DefaultPet.posterName).png")
        XCTAssertNotNil(NSImage(contentsOf: poster))
    }
}
