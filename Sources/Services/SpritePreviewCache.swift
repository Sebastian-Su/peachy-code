import AppKit
import CryptoKit

/// Sheets fetched only to preview a pet (petdex has no thumbnails). Kept on disk
/// so reopening "Browse more" still shows them and a later download reuses the
/// sheet; capped at `limitBytes`, dropping the least recently used first.
final class SpritePreviewCache: @unchecked Sendable {
    static let defaultLimitBytes = 200 * 1024 * 1024

    let directory: URL
    let limitBytes: Int
    private let transport: SpriteCatalogTransport
    private let lock = NSLock()
    private var frames: [String: CGImage] = [:]

    init(directory: URL = LocalStorage.appSupportDir.appendingPathComponent("SpritePreviews", isDirectory: true),
         transport: SpriteCatalogTransport = URLSessionCatalogTransport(),
         limitBytes: Int = SpritePreviewCache.defaultLimitBytes) {
        self.directory = directory
        self.transport = transport
        self.limitBytes = limitBytes
    }

    /// First idle frame of the pet, downloading its sheet once.
    func preview(_ pet: SpriteCatalogPet) async throws -> CGImage {
        if let frame = cachedFrame(pet) { return frame }
        let data = try await transport.data(from: pet.sheet)
        guard let frame = Self.idleFrame(from: data) else { throw PetPackError.invalidPack }
        try store(data, key: pet.slug)
        lock.withLock { frames[pet.slug] = frame }
        return frame
    }

    /// The preview frame if this pet was previewed before (this run or an earlier one).
    func cachedFrame(_ pet: SpriteCatalogPet) -> CGImage? {
        if let frame = lock.withLock({ frames[pet.slug] }) { return frame }
        guard let data = data(key: pet.slug), let frame = Self.idleFrame(from: data) else { return nil }
        lock.withLock { frames[pet.slug] = frame }
        return frame
    }

    func cachedSheet(_ pet: SpriteCatalogPet) -> Data? { data(key: pet.slug) }

    // MARK: - Disk store

    func store(_ data: Data, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(key), options: .atomic)
        evict(keeping: file(key))
    }

    /// Reading marks the entry as recently used.
    func data(key: String) -> Data? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    var totalBytes: Int { entries().reduce(0) { $0 + $1.size } }

    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func entries() -> [(url: URL, size: Int, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func evict(keeping newest: URL) {
        var all = entries().sorted { $0.used < $1.used }
        var total = all.reduce(0) { $0 + $1.size }
        while total > limitBytes, let oldest = all.first {
            all.removeFirst()
            if oldest.url.standardizedFileURL == newest.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    private static func idleFrame(from data: Data) -> CGImage? {
        guard let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let rows = SpriteSlicer.rows(of: cg)
        guard let row = SpritePetInstaller.resolvedRows([SpritePetInstaller.SheetRow.idle], available: rows).first else { return nil }
        return rows[row]?.first
    }
}
