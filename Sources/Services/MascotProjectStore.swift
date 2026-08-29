import CryptoKit
import Foundation
import Observation

enum MascotProjectStoreError: LocalizedError {
    case invalidRelativePath(String)
    case projectNotFound(UUID)
    case projectAlreadyExists(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path): String(format: t("creator.error.unsafe_asset_path"), path)
        case .projectNotFound(let id): String(format: t("creator.error.project_not_found_id"), id.uuidString)
        case .projectAlreadyExists(let id): String(format: t("creator.error.project_exists"), id.uuidString)
        }
    }
}

@Observable
final class MascotProjectStore {
    private(set) var projects: [MascotProject] = []
    let rootURL: URL

    init(rootURL: URL = LocalStorage.appSupportDir.appendingPathComponent("Mascots", isDirectory: true)) {
        self.rootURL = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        projects = urls.compactMap { directory in
            let file = directory.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? Self.decoder.decode(MascotProject.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func project(id: UUID) -> MascotProject? {
        projects.first { $0.id == id }
    }

    func createProject(
        name: String,
        stylePrompt: String,
        states: [MascotStateTemplate],
        providerID: String = MockMediaGenerationProvider.providerID
    ) throws -> MascotProject {
        let project = MascotProject.make(
            name: name,
            stylePrompt: stylePrompt,
            states: states,
            providerID: providerID
        )
        try FileManager.default.createDirectory(
            at: projectDirectory(for: project.id),
            withIntermediateDirectories: true
        )
        try save(project)
        return project
    }

    func save(_ project: MascotProject) throws {
        var value = project
        value.updatedAt = Date()
        let directory = projectDirectory(for: value.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        try data.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
        if let index = projects.firstIndex(where: { $0.id == value.id }) {
            projects[index] = value
        } else {
            projects.append(value)
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    func projectDirectory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func assetURL(_ asset: MascotAsset, projectID: UUID) throws -> URL {
        try safeURL(relativePath: asset.relativePath, projectID: projectID)
    }

    func writeAsset(
        _ data: Data,
        relativePath: String,
        mediaType: MascotMediaType,
        projectID: UUID
    ) throws -> MascotAsset {
        let destination = try safeURL(relativePath: relativePath, projectID: projectID)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return MascotAsset(
            relativePath: relativePath,
            sha256: Self.sha256(data),
            mediaType: mediaType
        )
    }

    func importAsset(
        from source: URL,
        relativePath: String,
        mediaType: MascotMediaType,
        projectID: UUID
    ) throws -> MascotAsset {
        try writeAsset(
            Data(contentsOf: source),
            relativePath: relativePath,
            mediaType: mediaType,
            projectID: projectID
        )
    }

    func installImportedProject(_ project: MascotProject, from packageURL: URL) throws {
        let destination = projectDirectory(for: project.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MascotProjectStoreError.projectAlreadyExists(project.id)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try SafeFileTree.copyContents(
            from: packageURL,
            to: destination,
            excluding: [MascotPackageService.manifestFilename],
            invalidPath: MascotProjectStoreError.invalidRelativePath
        )
        try save(project)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private func safeURL(relativePath: String, projectID: UUID) throws -> URL {
        try SafeFileTree.safeURL(
            relativePath: relativePath,
            under: projectDirectory(for: projectID),
            resolveSymlinks: false,
            invalidPath: MascotProjectStoreError.invalidRelativePath
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
