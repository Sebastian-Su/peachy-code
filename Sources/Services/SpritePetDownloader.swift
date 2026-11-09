import Foundation

/// Downloads one catalog pet (its sheet, plus petdex's `pet.json`) into a scratch
/// folder and installs it with the same checks as a local import. Only the pet
/// the user picked is fetched.
struct SpritePetDownloader {
    let transport: SpriteCatalogTransport
    let petsRoot: URL
    let workDirectory: URL

    init(transport: SpriteCatalogTransport = URLSessionCatalogTransport(),
         petsRoot: URL = LocalStorage.appSupportDir.appendingPathComponent("Pets", isDirectory: true),
         workDirectory: URL = FileManager.default.temporaryDirectory) {
        self.transport = transport
        self.petsRoot = petsRoot
        self.workDirectory = workDirectory
    }

    func install(_ pet: SpriteCatalogPet, sheetData: Data? = nil) async throws -> SpritePetInstaller.Installed {
        let fm = FileManager.default
        let pack = workDirectory.appendingPathComponent("sprite-download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: pack, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: pack) }

        var manifest: [String: Any] = ["id": pet.id, "displayName": pet.name, "spritesheetPath": "spritesheet.webp"]
        if let description = pet.description { manifest["description"] = description }
        if let url = pet.manifest,
           let remote = try JSONSerialization.jsonObject(with: await transport.data(from: url)) as? [String: Any] {
            // The catalog's id is the one we key on; the manifest supplies name, description and sheet path.
            manifest.merge(remote) { _, new in new }
            manifest["id"] = pet.id
        }
        guard let sheetPath = manifest["spritesheetPath"] as? String else { throw PetPackError.invalidPack }
        let sheetURL = try SafeFileTree.safeURL(relativePath: sheetPath, under: pack, resolveSymlinks: false,
                                                invalidPath: { PetPackError.unsafePath($0) })
        try fm.createDirectory(at: sheetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data: Data
        if let sheetData { data = sheetData } else { data = try await transport.data(from: pet.sheet) }
        try data.write(to: sheetURL)
        try JSONSerialization.data(withJSONObject: manifest).write(to: pack.appendingPathComponent("pet.json"))
        return try SpritePetInstaller.install(directory: pack, source: pet.source, into: petsRoot)
    }
}
