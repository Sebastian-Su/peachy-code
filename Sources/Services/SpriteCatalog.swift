// Loading approach (both sources fetched independently, one retry on transient
// failures, a malformed entry skipped instead of failing the list) is adapted
// from AgentPet's PetBrowser (https://github.com/ntd4996/agentpet), MIT License,
// Copyright (c) 2026 Nguyễn Thành Đạt. See ThirdPartyNotices.md.
import Foundation

/// One pet in an online spritesheet catalog.
struct SpriteCatalogPet: Codable, Identifiable, Equatable {
    let source: SpritePetSource
    let id: String
    let name: String
    let author: String?
    let kind: String?
    let thumbnail: URL?
    let sheet: URL
    /// petdex links the pack's `pet.json`; openpets gives the description inline.
    let manifest: URL?
    let description: String?

    /// Same key the library uses, so "installed" matches source and id together.
    var slug: String { SpritePetInstaller.slug(source: source, id: id) }
}

protocol SpriteCatalogTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionCatalogTransport: SpriteCatalogTransport {
    func data(from url: URL) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<2 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (200..<300).contains(code) { return data }
                lastError = URLError(.badServerResponse)
                guard code == 429 || code >= 500 else { break }
            } catch {
                lastError = error
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw lastError
    }
}

/// Reads the openpets and petdex catalogs directly from their sites (no mirror),
/// caching each list on disk so the browser shows the last copy before the network answers.
final class SpriteCatalog: @unchecked Sendable {
    static let openpetsIndex = URL(string: "https://openpets.dev/pets/catalog.v3.json")!
    static let petdexManifest = URL(string: "https://petdex.dev/api/manifest")!

    private let transport: SpriteCatalogTransport
    private let cacheDirectory: URL

    init(transport: SpriteCatalogTransport = URLSessionCatalogTransport(),
         cacheDirectory: URL = LocalStorage.appSupportDir.appendingPathComponent("SpriteCatalogs", isDirectory: true)) {
        self.transport = transport
        self.cacheDirectory = cacheDirectory
    }

    /// Fetches a source's full list and refreshes its cache.
    func load(_ source: SpritePetSource) async throws -> [SpriteCatalogPet] {
        let pets: [SpriteCatalogPet]
        switch source {
        case .petdex:
            pets = try Self.decodePetdex(await transport.data(from: Self.petdexManifest))
        case .openpets:
            let index = try JSONDecoder().decode(OpenpetsIndex.self, from: await transport.data(from: Self.openpetsIndex))
            var all: [SpriteCatalogPet] = []
            for page in index.pages {
                all += try Self.decodeOpenpetsPage(await transport.data(from: page))
            }
            pets = Self.dedupe(all)
        case .local:
            return []
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(pets).write(to: cacheURL(source), options: .atomic)
        return pets
    }

    /// Last list saved on disk, if any.
    func cached(_ source: SpritePetSource) -> [SpriteCatalogPet]? {
        guard let data = try? Data(contentsOf: cacheURL(source)) else { return nil }
        return try? JSONDecoder().decode([SpriteCatalogPet].self, from: data)
    }

    private func cacheURL(_ source: SpritePetSource) -> URL {
        cacheDirectory.appendingPathComponent("\(source.rawValue).json")
    }

    static func filter(_ pets: [SpriteCatalogPet], query: String, kind: String?) -> [SpriteCatalogPet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return pets.filter { pet in
            (kind == nil || pet.kind == kind)
                && (q.isEmpty || pet.name.lowercased().contains(q) || pet.id.lowercased().contains(q))
        }
    }

    // MARK: - Decoding

    /// Decodes `T` but tolerates a malformed element (yields `nil` instead of failing the array).
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }

    private struct PetdexManifest: Decodable { let pets: [Lenient<PetdexEntry>] }
    private struct PetdexEntry: Decodable {
        let slug: String
        let displayName: String?
        let kind: String?
        let submittedBy: String?
        let spritesheetUrl: URL
        let petJsonUrl: URL?
    }

    private struct OpenpetsIndex: Decodable { let pages: [URL] }
    private struct OpenpetsPage: Decodable { let pets: [Lenient<OpenpetsEntry>] }
    private struct OpenpetsEntry: Decodable {
        let id: String
        let displayName: String?
        let description: String?
        let thumbnail: URL?
        let spritesheet: URL
        let category: String?
    }

    static func decodePetdex(_ data: Data) throws -> [SpriteCatalogPet] {
        dedupe(try JSONDecoder().decode(PetdexManifest.self, from: data).pets.compactMap(\.value)
            .filter { SpritePetInstaller.isSafeId($0.slug) }
            .map {
                SpriteCatalogPet(source: .petdex, id: $0.slug, name: $0.displayName ?? $0.slug,
                                 author: $0.submittedBy?.trimmingCharacters(in: .whitespaces).nilIfEmpty, kind: $0.kind,
                                 thumbnail: nil, sheet: $0.spritesheetUrl, manifest: $0.petJsonUrl, description: nil)
            })
    }

    static func decodeOpenpetsPage(_ data: Data) throws -> [SpriteCatalogPet] {
        try JSONDecoder().decode(OpenpetsPage.self, from: data).pets.compactMap(\.value)
            .filter { SpritePetInstaller.isSafeId($0.id) }
            .map {
                SpriteCatalogPet(source: .openpets, id: $0.id, name: $0.displayName ?? $0.id, author: nil, kind: $0.category,
                                 thumbnail: $0.thumbnail, sheet: $0.spritesheet, manifest: nil, description: $0.description)
            }
    }

    private static func dedupe(_ pets: [SpriteCatalogPet]) -> [SpriteCatalogPet] {
        var seen = Set<String>()
        return pets.filter { seen.insert($0.slug).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
