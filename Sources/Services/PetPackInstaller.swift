import Foundation

/// The online pet list: one entry per downloadable pet pack.
struct PetCatalog: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let version: String
        let preview: URL?
        let download: URL
        let sha256: String
        let size: Int?
    }

    let schemaVersion: Int
    let pets: [Entry]
}

enum PetPackError: LocalizedError, Equatable {
    case checksumMismatch
    case invalidPack
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: t("pets.error.checksum")
        case .invalidPack: t("pets.error.invalid")
        case .unsafePath(let path): String(format: t("pets.error.unsafe_path"), path)
        }
    }
}

/// Installs a pet pack: a zip holding `pet.json` (an animation config whose media
/// paths are relative to the pack) plus the media files. The archive is checked
/// against the catalog's SHA-256 before anything is unpacked, and every media
/// path must stay inside the pack.
enum PetPackInstaller {
    static let configFilename = "pet.json"

    static func install(archive: URL, expectedSHA256: String, into destination: URL) throws -> PeachyAnimationConfig {
        guard MascotProjectStore.sha256(fileAt: archive)?.lowercased() == expectedSHA256.lowercased() else {
            throw PetPackError.checksumMismatch
        }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw PetPackError.invalidPack }

        let root = try packRoot(in: staging)
        guard let data = try? Data(contentsOf: root.appendingPathComponent(configFilename)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PetPackError.invalidPack
        }
        // Rewrite relative media paths to their final location before moving the pack in place.
        json = try rewriteMedia(json, packRoot: root, finalRoot: destination) as? [String: Any] ?? json
        let rewritten = try JSONSerialization.data(withJSONObject: json)
        guard let config = try? JSONDecoder().decode(PeachyAnimationConfig.self, from: rewritten) else {
            throw PetPackError.invalidPack
        }

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: root, to: destination)
        return config
    }

    /// ditto may unpack into a single top-level folder; use it when pet.json is not at the top.
    private static func packRoot(in staging: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appendingPathComponent(configFilename).path) { return staging }
        let children = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX") }
        if children.count == 1, fm.fileExists(atPath: children[0].appendingPathComponent(configFilename).path) {
            return children[0]
        }
        throw PetPackError.invalidPack
    }

    private static let mediaKeys: Set<String> = ["hevc", "webm", "transparentThumbnailUrl", "url"]

    private static func rewriteMedia(_ value: Any, packRoot: URL, finalRoot: URL) throws -> Any {
        if let dict = value as? [String: Any] {
            var out = dict
            for (key, child) in dict {
                if mediaKeys.contains(key), let path = child as? String, URL(string: path)?.scheme == nil {
                    _ = try SafeFileTree.safeURL(relativePath: path, under: packRoot, resolveSymlinks: true,
                                                 invalidPath: { PetPackError.unsafePath($0) })
                    out[key] = finalRoot.appendingPathComponent(path).absoluteString
                } else {
                    out[key] = try rewriteMedia(child, packRoot: packRoot, finalRoot: finalRoot)
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return try array.map { try rewriteMedia($0, packRoot: packRoot, finalRoot: finalRoot) }
        }
        return value
    }
}
