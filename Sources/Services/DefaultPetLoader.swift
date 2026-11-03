import AppKit
import Observation

/// The default pet for new installs. Its videos come from the resource center;
/// only a still poster ships in the app so something shows before the download.
enum DefaultPet {
    static let packId = "peachmilky"
    static let slug = "pack:\(packId)"
    static let name = "PeachMilky"
    static let posterName = "peachmilky-poster"

    static var poster: NSImage? {
        PeachyResourceBundle.current.url(forResource: posterName, withExtension: "png", subdirectory: "Images")
            .flatMap(NSImage.init(contentsOf:))
    }
}

/// Downloads and installs the default pet. Failure is a visible, retryable state,
/// never an error that stops the app.
@MainActor
@Observable
final class DefaultPetLoader {
    enum State: Equatable {
        case idle
        case downloading
        case failed(String)
        case ready
    }

    static let shared = DefaultPetLoader()

    private(set) var state: State = .idle
    @ObservationIgnored private let catalogURL: () -> URL

    init(catalogURL: @autoclosure @escaping () -> URL = Constants.petCatalogURL) {
        self.catalogURL = catalogURL
    }

    /// Returns the default pet's config, downloading it first if needed.
    func ensureInstalled(into store: MascotStore) async -> PeachyAnimationConfig? {
        if let existing = store.mascots.first(where: { $0.templateSlug == DefaultPet.slug }) {
            state = .ready
            return existing.config
        }
        guard state != .downloading else { return nil }
        state = .downloading
        do {
            let (data, _) = try await URLSession.shared.data(from: catalogURL())
            let catalog = try JSONDecoder().decode(PetCatalog.self, from: data)
            guard let entry = catalog.pets.first(where: { $0.id == DefaultPet.packId }) else {
                throw PetPackError.invalidPack
            }
            let (archive, _) = try await URLSession.shared.download(from: entry.download)
            let destination = LocalStorage.appSupportDir.appendingPathComponent("Pets/\(entry.id)", isDirectory: true)
            let config = try PetPackInstaller.install(archive: archive, expectedSHA256: entry.sha256, into: destination)
            store.addOrReplacePack(config: config, packId: entry.id)
            state = .ready
            return config
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }
}
