import Foundation

/// A launchd job PeachyPet shows on the Services page (brew service or LaunchAgent).
struct SystemService: Identifiable, Equatable {
    enum Group: Equatable {
        case brew
        /// The user's own LaunchAgent (program in the home folder or Homebrew).
        case userAgent
        /// Installed by an app; shown read-only.
        case appAgent
        /// The user's own LaunchDaemon (needs root); shown read-only.
        case daemon
    }

    let label: String
    let name: String
    let group: Group
    let plistPath: String
    let program: String?
    var pid: Int32?
    /// Loaded into launchd right now (may be loaded but not running).
    var loaded: Bool
    /// Starts at login: brew service registered, or agent plist not disabled.
    var autostart: Bool?

    var id: String { label }
    var isRunning: Bool { pid != nil }
    var isOperable: Bool { group == .brew || group == .userAgent }
}

enum SystemServiceAction: Equatable {
    case start, stop, restart
}

/// Commands for one run only; never changes whether a service starts at login.
enum SystemServiceActions {
    static func plan(_ action: SystemServiceAction, for service: SystemService, uid: uid_t) -> [[String]] {
        let target = "gui/\(uid)/\(service.label)"
        switch action {
        case .stop:
            // bootout unloads the job, so KeepAlive cannot respawn it; the plist stays.
            return service.loaded ? [["/bin/launchctl", "bootout", target]] : []
        case .start:
            if service.loaded { return [["/bin/launchctl", "kickstart", target]] }
            if service.group == .brew && service.autostart != true {
                // Not registered for login: run it once without registering.
                return [[BrewServices.brewPath, "services", "run", service.name]]
            }
            return [["/bin/launchctl", "bootstrap", "gui/\(uid)", service.plistPath]]
        case .restart:
            if service.loaded { return [["/bin/launchctl", "kickstart", "-k", target]] }
            return plan(.start, for: service, uid: uid)
        }
    }

    /// Runs the planned commands; returns the first failure's output.
    @discardableResult
    static func perform(_ action: SystemServiceAction, on service: SystemService) -> String? {
        guard service.isOperable else { return "read-only" }
        for command in plan(action, for: service, uid: getuid()) {
            let (status, output) = run(command)
            if status != 0 { return output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    static func run(_ command: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

enum BrewServices {
    struct Item: Equatable {
        let name: String
        let status: String
        let file: String
        var label: String { ((file as NSString).lastPathComponent as NSString).deletingPathExtension }
        /// Registered for login when its plist is installed in LaunchAgents.
        let registered: Bool
    }

    static var brewPath: String {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/brew"
    }

    static var launchAgentsDir: String { NSHomeDirectory() + "/Library/LaunchAgents" }

    static func parse(_ data: Data, launchAgentsDir: String = BrewServices.launchAgentsDir) -> [Item]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array.compactMap { obj in
            guard let name = obj["name"] as? String, let file = obj["file"] as? String else { return nil }
            return Item(name: name, status: obj["status"] as? String ?? "", file: file,
                        registered: (file as NSString).deletingLastPathComponent == launchAgentsDir)
        }
    }

    /// `brew services list --json`, read-only. Returns nil if brew is missing.
    static func list() -> [Item]? {
        guard FileManager.default.isExecutableFile(atPath: brewPath) else { return nil }
        let (status, output) = SystemServiceActions.run([brewPath, "services", "list", "--json"])
        guard status == 0 else { return nil }
        return parse(Data(output.utf8))
    }
}

/// launchd state of one job in the user's GUI domain, read-only.
enum LaunchdState {
    static func read(label: String, uid: uid_t = getuid()) -> (loaded: Bool, pid: Int32?) {
        let (status, output) = SystemServiceActions.run(["/bin/launchctl", "print", "gui/\(uid)/\(label)"])
        guard status == 0 else { return (false, nil) }
        let pid = output.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
            .flatMap { Int32($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }
        return (true, pid)
    }
}

/// Builds the system-service list shown on the page.
enum SystemServiceCatalog {
    static func build(brew: [BrewServices.Item]) -> [SystemService] {
        brew.map { item in
            let state = LaunchdState.read(label: item.label)
            return SystemService(label: item.label, name: item.name, group: .brew, plistPath: item.file,
                                 program: nil, pid: state.pid, loaded: state.loaded, autostart: item.registered)
        }
    }
}
