import Foundation

/// First-run confirmation for registered commands. Stores a fingerprint of what
/// actually runs (command, working directory, environment) in PeachyPet's own
/// defaults, never in the registry file, so a rewritten file cannot claim to be
/// approved.
final class ServiceApproval {
    enum Field: String, Equatable { case command, cwd, env }

    enum Status: Equatable {
        case neverApproved
        case approved
        /// Approved before, but these fields changed since.
        case changed([Field])
    }

    static let shared = ServiceApproval()
    private static let key = "serviceApprovals"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func fingerprint(_ entry: ServiceEntry) -> [String: String] {
        [
            Field.command.rawValue: entry.command,
            Field.cwd.rawValue: entry.cwd ?? "",
            Field.env.rawValue: entry.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"),
        ]
    }

    func status(of entry: ServiceEntry) -> Status {
        guard let saved = (defaults.dictionary(forKey: Self.key) ?? [:])[entry.id] as? [String: String] else {
            return .neverApproved
        }
        let now = Self.fingerprint(entry)
        let changed = [Field.command, .cwd, .env].filter { saved[$0.rawValue] != now[$0.rawValue] }
        return changed.isEmpty ? .approved : .changed(changed)
    }

    func approve(_ entry: ServiceEntry) {
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        all[entry.id] = Self.fingerprint(entry)
        defaults.set(all, forKey: Self.key)
    }
}
