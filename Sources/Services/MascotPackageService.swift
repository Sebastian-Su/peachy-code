import Foundation

struct MascotPackageManifest: Codable {
    let schemaVersion: Int
    let project: MascotProject
    let checksums: [String: String]
}

enum MascotPackageError: LocalizedError {
    case destinationExists
    case invalidPackage
    case unsafePath(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .destinationExists: t("creator.error.destination_exists")
        case .invalidPackage: t("creator.error.invalid_package")
        case .unsafePath(let path): String(format: t("creator.error.unsafe_package_path"), path)
        case .checksumMismatch(let path): String(format: t("creator.error.checksum_mismatch"), path)
        }
    }
}

struct MascotPackageService {
    static let manifestFilename = "manifest.json"

    func export(project: MascotProject, from sourceDirectory: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MascotPackageError.destinationExists
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try SafeFileTree.copyContents(
                from: sourceDirectory,
                to: destination,
                invalidPath: MascotPackageError.unsafePath
            )
            let checksums = try fileChecksums(in: destination)
            let manifest = MascotPackageManifest(schemaVersion: 1, project: project, checksums: checksums)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: destination.appendingPathComponent(Self.manifestFilename),
                options: .atomic
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func importPackage(at packageURL: URL, into store: MascotProjectStore) throws -> MascotProject {
        let manifestURL = packageURL.appendingPathComponent(Self.manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw MascotPackageError.invalidPackage
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(MascotPackageManifest.self, from: data),
              manifest.schemaVersion == 1 else {
            throw MascotPackageError.invalidPackage
        }
        for (relativePath, expectedHash) in manifest.checksums {
            let fileURL = try safePackageURL(relativePath, packageURL: packageURL)
            guard let fileData = try? Data(contentsOf: fileURL),
                  MascotProjectStore.sha256(fileData) == expectedHash else {
                throw MascotPackageError.checksumMismatch(relativePath)
            }
        }
        var project = manifest.project
        if store.project(id: project.id) != nil {
            project.id = UUID()
            project.name += " Copy"
        }
        try store.installImportedProject(project, from: packageURL)
        return project
    }

    private func fileChecksums(in directory: URL) throws -> [String: String] {
        var checksums: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = try SafeFileTree.relativePath(
                of: file,
                under: directory,
                invalidPath: MascotPackageError.unsafePath
            )
            guard relative != Self.manifestFilename else { continue }
            checksums[relative] = MascotProjectStore.sha256(try Data(contentsOf: file))
        }
        return checksums
    }

    private func safePackageURL(_ relativePath: String, packageURL: URL) throws -> URL {
        try SafeFileTree.safeURL(
            relativePath: relativePath,
            under: packageURL,
            resolveSymlinks: true,
            invalidPath: MascotPackageError.unsafePath
        )
    }
}
