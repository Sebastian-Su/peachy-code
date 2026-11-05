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

    /// Login-start change for brew services and the user's own agents. Only
    /// `launchctl enable/disable`, which affect the next login and leave the
    /// running process alone; registering an unregistered brew service needs
    /// `brew services start`, which also starts it now (`startsNow`).
    static func planAutostart(_ enable: Bool, for service: SystemService, uid: uid_t) -> (commands: [[String]], startsNow: Bool) {
        guard service.isOperable else { return ([], false) }
        let target = "gui/\(uid)/\(service.label)"
        // A brew service is registered for login once its plist sits in LaunchAgents.
        let registered = service.group == .userAgent || service.plistPath.contains("/Library/LaunchAgents/")
        if enable && service.group == .brew && !registered {
            return ([[BrewServices.brewPath, "services", "start", service.name]], true)
        }
        if !enable && service.group == .brew && !registered { return ([], false) }
        return ([["/bin/launchctl", enable ? "enable" : "disable", target]], false)
    }

    @discardableResult
    static func setAutostart(_ enable: Bool, on service: SystemService) -> String? {
        guard service.isOperable else { return "read-only" }
        for command in planAutostart(enable, for: service, uid: getuid()).commands {
            let (status, output) = run(command)
            if status != 0 { return output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
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
    /// Labels turned off for login in the user's GUI domain.
    static func disabledLabels(uid: uid_t = getuid()) -> Set<String> {
        parseDisabled(SystemServiceActions.run(["/bin/launchctl", "print-disabled", "gui/\(uid)"]).1)
    }

    static func parseDisabled(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "disabled" else { return nil }
            return parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        })
    }

    static func read(label: String, system: Bool = false, uid: uid_t = getuid()) -> (loaded: Bool, pid: Int32?) {
        let domain = system ? "system" : "gui/\(uid)"
        let (status, output) = SystemServiceActions.run(["/bin/launchctl", "print", "\(domain)/\(label)"])
        guard status == 0 else { return (false, nil) }
        let pid = output.split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
            .flatMap { Int32($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }
        return (true, pid)
    }
}

/// One launchd plist on disk.
struct LaunchPlist: Equatable {
    enum Location: Equatable { case userAgents, systemAgents, systemDaemons }

    let label: String
    let program: String?
    let path: String
    let location: Location
    let runAtLoad: Bool

    static func read(_ url: URL, location: Location) -> LaunchPlist? {
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = dict["Label"] as? String else { return nil }
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        return LaunchPlist(label: label, program: program.flatMap { $0.isEmpty ? nil : $0 }, path: url.path,
                           location: location, runAtLoad: dict["RunAtLoad"] as? Bool ?? false)
    }

    static func readAll(in directory: String, location: Location) -> [LaunchPlist] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "plist" }.compactMap { read($0, location: location) }
    }
}

/// Builds the system-service list shown on the page.
enum SystemServiceCatalog {
    /// Which group a plist belongs to; nil means not shown at all (other people's daemons).
    static func group(for plist: LaunchPlist, home: String = NSHomeDirectory()) -> SystemService.Group? {
        let program = plist.program ?? ""
        let insideApp = program.contains(".app/")
        let userOwned = !insideApp && !program.isEmpty && (
            (program.hasPrefix(home + "/") && !program.hasPrefix(home + "/Library/"))
                || program.hasPrefix("/opt/homebrew/") || program.hasPrefix("/usr/local/"))
        switch plist.location {
        case .userAgents: return userOwned ? .userAgent : .appAgent
        case .systemAgents: return .appAgent
        case .systemDaemons: return userOwned ? .daemon : nil
        }
    }

    static func build(
        brew: [BrewServices.Item],
        plists: [LaunchPlist] = defaultPlists(),
        home: String = NSHomeDirectory(),
        disabled: Set<String> = LaunchdState.disabledLabels(),
        state: (String, Bool) -> (loaded: Bool, pid: Int32?) = { label, system in LaunchdState.read(label: label, system: system) }
    ) -> [SystemService] {
        var result = brew.map { item -> SystemService in
            let s = state(item.label, false)
            return SystemService(label: item.label, name: item.name, group: .brew, plistPath: item.file,
                                 program: nil, pid: s.pid, loaded: s.loaded,
                                 autostart: item.registered && !disabled.contains(item.label))
        }
        let brewLabels = Set(brew.map(\.label))
        for plist in plists where !brewLabels.contains(plist.label) {
            guard let group = group(for: plist, home: home) else { continue }
            let s = state(plist.label, plist.location == .systemDaemons)
            result.append(SystemService(label: plist.label, name: plist.label, group: group, plistPath: plist.path,
                                        program: plist.program, pid: s.pid, loaded: s.loaded,
                                        autostart: plist.runAtLoad && !disabled.contains(plist.label)))
        }
        return result
    }

    static func defaultPlists() -> [LaunchPlist] {
        LaunchPlist.readAll(in: NSHomeDirectory() + "/Library/LaunchAgents", location: .userAgents)
            + LaunchPlist.readAll(in: "/Library/LaunchAgents", location: .systemAgents)
            + LaunchPlist.readAll(in: "/Library/LaunchDaemons", location: .systemDaemons)
    }

    /// Daemons need root; PeachyPet only offers this command for the user to run.
    static func sudoCommand(for service: SystemService) -> String {
        "sudo launchctl kickstart -k system/\(service.label)"
    }
}
