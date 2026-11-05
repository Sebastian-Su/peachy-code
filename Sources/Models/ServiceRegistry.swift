import Foundation

/// One user-registered start command, read from the services registry
/// directory (one JSON file per service, file name = id).
struct ServiceEntry: Equatable {
    enum Kind: String, Codable, Equatable {
        /// Long-running: start / stop / restart.
        case service
        /// Runs to completion: execute, then show the result.
        case task
    }

    let id: String
    let name: String
    let kind: Kind
    let command: String
    /// Absolute, with `~` expanded.
    let cwd: String?
    let url: URL?
    let port: Int?
    let env: [String: String]
    let note: String?
    let fileURL: URL
    let modifiedAt: Date?
}

struct ServiceRegistryItem: Identifiable, Equatable {
    enum State: Equatable {
        case valid(ServiceEntry)
        case invalid(ServiceRegistryError)
    }

    let id: String
    let fileURL: URL
    let state: State
}

/// Why a registry file could not be used. Localized when shown, so a language
/// switch updates the message.
enum ServiceRegistryError: Equatable {
    case badId(String)
    case notJSON
    case unknownSchema(Int)
    case unknownKind(String)
    case missing(String)

    var message: String {
        switch self {
        case .badId(let id): String(format: t("services.error.bad_id"), id)
        case .notJSON: t("services.error.not_json")
        case .unknownSchema(let v): String(format: t("services.error.schema"), v)
        case .unknownKind(let k): String(format: t("services.error.kind"), k)
        case .missing(let f): String(format: t("services.error.missing"), f)
        }
    }
}

enum ServiceRegistry {
    static let schemaVersion = 1

    /// `~/.peachypet/services`; tests pass their own directory.
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".peachypet/services", isDirectory: true)
    }

    static func isValidId(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func expandTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
        return path
    }

    /// Every `.json` file in the directory, sorted by id. A bad file becomes an
    /// `.invalid` item with a reason; it never hides the others.
    static func load(from directory: URL = defaultDirectory) -> [ServiceRegistryItem] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                return ServiceRegistryItem(id: id, fileURL: url, state: parse(fileURL: url, id: id))
            }
            .sorted { $0.id < $1.id }
    }

    static func parse(fileURL: URL, id: String) -> ServiceRegistryItem.State {
        guard isValidId(id) else {
            return .invalid(.badId(id))
        }
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid(.notJSON)
        }
        guard let schema = json["schema"] as? Int else { return .invalid(.missing("schema")) }
        guard schema == schemaVersion else {
            return .invalid(.unknownSchema(schema))
        }
        guard let name = nonEmpty(json["name"]) else { return .invalid(.missing("name")) }
        guard let kindRaw = json["kind"] as? String else { return .invalid(.missing("kind")) }
        guard let kind = ServiceEntry.Kind(rawValue: kindRaw) else {
            return .invalid(.unknownKind(kindRaw))
        }
        guard let command = nonEmpty(json["command"]) else { return .invalid(.missing("command")) }
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return .valid(ServiceEntry(
            id: id,
            name: name,
            kind: kind,
            command: command,
            cwd: nonEmpty(json["cwd"]).map(expandTilde),
            url: nonEmpty(json["url"]).flatMap(URL.init(string:)),
            port: (json["port"] as? Int).flatMap { (1...65535).contains($0) ? $0 : nil },
            env: (json["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:],
            note: nonEmpty(json["note"]),
            fileURL: fileURL,
            modifiedAt: modified
        ))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
