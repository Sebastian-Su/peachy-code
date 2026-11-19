import Foundation

/// JSON file persistence for ~/Library/Application Support/PeachyPet/
enum LocalStorage {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Isolate test runs so unit tests never read or write the real user data.
        let isRunningTests = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let dir = isRunningTests
            ? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PeachyPetTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : base.appendingPathComponent("PeachyPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func save<T: Encodable>(_ value: T, to filename: String) {
        let url = appSupportDir.appendingPathComponent(filename)
        do {
            let data = try redacted(JSONEncoder().encode(value))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[PeachyPet] Failed to save \(filename): \(error)")
        }
    }

    /// One serial queue for every background write: files keep their write order and the
    /// main thread never encodes, redacts or writes.
    private static let writer = DispatchQueue(label: "PeachyPet.LocalStorage", qos: .utility)

    /// Saves on the background writer. The value is a copy, so later changes do not race it.
    static func saveInBackground<T: Encodable>(_ value: T, to filename: String) {
        writer.async { save(value, to: filename) }
    }

    /// Waits for queued writes. Call before the process exits.
    static func flush() {
        writer.sync {}
    }

    /// Credentials in saved commands and messages never reach disk.
    private static func redacted(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try JSONSerialization.data(withJSONObject: SecretRedactor.redactJSON(object), options: .fragmentsAllowed)
    }

    static func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = appSupportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            print("[PeachyPet] Failed to load \(filename): \(error)")
            return nil
        }
    }
}
