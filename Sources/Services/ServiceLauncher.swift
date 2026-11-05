import Foundation

/// Starts registered commands as transient launchd jobs (`com.peachypet.service.<id>`):
/// the job outlives PeachyPet, is not loaded at login, and is removed on stop.
/// Nothing is started unless the user approved the exact command (see ServiceApproval).
final class ServiceLauncher {
    enum LaunchError: Error, Equatable {
        case needsApproval
        case launchctlFailed(String)
    }

    static let labelPrefix = "com.peachypet.service."
    static let shared = ServiceLauncher()

    private let approvals: ServiceApproval
    private let runLaunchctl: ([String]) -> (Int32, String)

    init(approvals: ServiceApproval = .shared,
         runLaunchctl: @escaping ([String]) -> (Int32, String) = ServiceLauncher.launchctl) {
        self.approvals = approvals
        self.runLaunchctl = runLaunchctl
    }

    static func label(for id: String) -> String { labelPrefix + id }

    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PeachyPet/services", isDirectory: true)
    }

    static func logURL(for id: String) -> URL { logDirectory.appendingPathComponent("\(id).log") }

    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// The launchd job for one run. RunAtLoad starts it as soon as it is
    /// bootstrapped; there is no KeepAlive and the plist lives outside
    /// LaunchAgents, so it never starts at login.
    static func jobDefinition(for entry: ServiceEntry, shell: String, logURL: URL) -> [String: Any] {
        var job: [String: Any] = [
            "Label": label(for: entry.id),
            "ProgramArguments": [shell, "-lc", entry.command],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "RunAtLoad": true,
            "AbandonProcessGroup": false,
            "ProcessType": "Interactive",
        ]
        if let cwd = entry.cwd { job["WorkingDirectory"] = cwd }
        if !entry.env.isEmpty { job["EnvironmentVariables"] = entry.env }
        return job
    }

    /// Where the per-run job plist is written (inside PeachyPet's support dir, not LaunchAgents).
    static var jobDirectory: URL {
        LocalStorage.appSupportDir.appendingPathComponent("ServiceJobs", isDirectory: true)
    }

    func start(_ entry: ServiceEntry) throws {
        guard approvals.status(of: entry) == .approved else { throw LaunchError.needsApproval }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: Self.jobDirectory, withIntermediateDirectories: true)
        let log = Self.logURL(for: entry.id)
        ServiceLog.prepare(log)
        let plist = Self.jobDirectory.appendingPathComponent(Self.label(for: entry.id) + ".plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: Self.jobDefinition(for: entry, shell: Self.loginShell, logURL: log), format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        // A stale job with the same label (e.g. one that exited) would make bootstrap fail.
        _ = runLaunchctl(["remove", Self.label(for: entry.id)])
        let (status, output) = runLaunchctl(["bootstrap", Self.guiDomain, plist.path])
        guard status == 0 else { throw LaunchError.launchctlFailed(output) }
    }

    /// Unloads the job; launchd terminates its process group.
    func stop(id: String) {
        _ = runLaunchctl(["remove", Self.label(for: id)])
        try? FileManager.default.removeItem(at: Self.jobDirectory.appendingPathComponent(Self.label(for: id) + ".plist"))
    }

    /// PID of the job's main process, or nil if not loaded or not running.
    func runningPID(id: String) -> Int32? {
        let (status, output) = runLaunchctl(["print", "\(Self.guiDomain)/\(Self.label(for: id))"])
        guard status == 0,
              let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }),
              let pid = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
        return pid
    }

    /// Last exit status of a loaded job that is no longer running.
    func lastExitStatus(id: String) -> Int32? {
        let (status, output) = runLaunchctl(["print", "\(Self.guiDomain)/\(Self.label(for: id))"])
        guard status == 0,
              let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("last exit code = ") }),
              let code = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") else { return nil }
        return code
    }

    static var guiDomain: String { "gui/\(getuid())" }

    static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Per-service log file kept under 5 MB: a new run starts from the newest
/// half when the file is over the limit.
enum ServiceLog {
    static let maxBytes = 5 * 1024 * 1024

    static func prepare(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        try? handle.seek(toOffset: UInt64(size - maxBytes / 2))
        let tail = handle.readDataToEndOfFile()
        try? handle.close()
        try? tail.write(to: url, options: .atomic)
    }
}

/// What the Services page shows for a registered service. Reading it never starts anything.
enum ServiceRunState: Equatable {
    case stopped
    case running(pid: Int32)

    static func read(_ entry: ServiceEntry, launcher: ServiceLauncher) -> ServiceRunState {
        if let pid = launcher.runningPID(id: entry.id) { return .running(pid: pid) }
        return .stopped
    }
}
