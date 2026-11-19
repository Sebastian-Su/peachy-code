import Foundation

/// A process listening on a TCP port.
struct PortListener: Equatable {
    let pid: Int32
    let command: String
    let cwd: String

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpn` → port: pid.
    static func parseLsof(_ output: String) -> [Int: Int32] {
        var result: [Int: Int32] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid,
                      let port = Int(line.split(separator: ":").last ?? "") {
                if result[port] == nil { result[port] = pid }
            }
        }
        return result
    }

    /// All listening ports right now (one lsof call).
    static func listeningPorts() -> [Int: Int32] {
        parseLsof(run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]))
    }

    static func describe(pid: Int32) -> PortListener {
        let command = run("/bin/ps", ["-o", "command=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
            .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? ""
        return PortListener(pid: pid, command: command, cwd: cwd)
    }

    static func run(_ exe: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Running state of a registered service, combining launchd and the port.
enum ServiceStatus: Equatable {
    case stopped
    /// Started by PeachyPet (launchd job).
    case running(pid: Int32)
    /// Started elsewhere (terminal, an agent) and matched to this registration.
    case external(pid: Int32, command: String)
    /// The port is taken by a process that does not match this registration.
    case portBusy(pid: Int32, command: String)

    var isRunning: Bool {
        switch self {
        case .running, .external: true
        case .stopped, .portBusy: false
        }
    }

    /// Words that say how something is launched, not what it is.
    private static let genericWords: Set<String> = [
        "python", "python3", "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "uv", "uvx", "conda", "run",
        "exec", "env", "sh", "bash", "zsh", "make", "docker", "compose", "start", "dev", "serve", "server",
        "main", "app", "index", "sudo", "nohup", "cd", "source", "java", "go", "cargo", "ruby", "php",
    ]

    /// A listener matches when it runs in the registered directory, or its
    /// command shares a distinctive word with the registered command.
    static func matches(_ entry: ServiceEntry, _ listener: PortListener) -> Bool {
        if let cwd = entry.cwd, !listener.cwd.isEmpty {
            let a = URL(fileURLWithPath: cwd).standardizedFileURL.path
            let b = URL(fileURLWithPath: listener.cwd).standardizedFileURL.path
            if a == b || b.hasPrefix(a + "/") { return true }
        }
        let ours = distinctiveWords(entry.command)
        return !ours.isDisjoint(with: distinctiveWords(listener.command))
    }

    static func distinctiveWords(_ command: String) -> Set<String> {
        let tokens = command.split(whereSeparator: { " \t;&|()'\"".contains($0) })
        return Set(tokens.compactMap { token -> String? in
            guard !token.hasPrefix("-"), !token.contains("=") else { return nil }
            let base = (String(token) as NSString).lastPathComponent.lowercased()
            let stem = (base as NSString).deletingPathExtension
            guard stem.count >= 3, !genericWords.contains(stem), Int(stem) == nil else { return nil }
            return stem
        })
    }

    /// `pidFileProcess` is the live process named by the registration's PID file. It counts
    /// only when it matches the registration, since a stale file can name a reused PID.
    static func resolve(_ entry: ServiceEntry, managedPID: Int32?, listener: PortListener?,
                        pidFileProcess: PortListener? = nil) -> ServiceStatus {
        if let managedPID { return .running(pid: managedPID) }
        guard let listener else {
            if let process = pidFileProcess, matches(entry, process) {
                return .external(pid: process.pid, command: process.command)
            }
            return .stopped
        }
        return matches(entry, listener)
            ? .external(pid: listener.pid, command: listener.command)
            : .portBusy(pid: listener.pid, command: listener.command)
    }
}

/// A PID written by an instance started outside PeachyPet: plain digits, or a JSON object
/// with an integer `pid`.
enum ServicePIDFile {
    static func read(_ path: String) -> Int32? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(text), pid > 0 {
            return pid
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int, pid > 0, pid <= Int(Int32.max) else { return nil }
        return Int32(pid)
    }

    /// The live process the file names, described for matching.
    static func process(for entry: ServiceEntry) -> PortListener? {
        guard let path = entry.pidFile, let pid = read(path), kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return PortListener.describe(pid: pid)
    }
}

/// Ends a process the user confirmed: SIGTERM, then SIGKILL if it is still
/// alive after the grace period.
enum ProcessTerminator {
    static func terminate(
        pid: Int32,
        grace: TimeInterval = 10,
        send: (Int32, Int32) -> Void = { _ = kill($0, $1) },
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) {
        send(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !isAlive(pid) { return }
            Thread.sleep(forTimeInterval: min(0.2, grace))
        }
        if isAlive(pid) { send(pid, SIGKILL) }
    }
}

/// What pressing Restart has to do, given who owns the process and whether the
/// command has been confirmed. Every path that replaces a running process
/// waits for it to exit before starting the new one.
enum ServiceRestartFlow: Equatable {
    case none
    /// Our own job, command already confirmed.
    case restartManaged
    /// External process, command already confirmed: confirm ending the process.
    case confirmStopThenStart(pid: Int32, command: String)
    /// Our own job or stopped, command not confirmed yet.
    case confirmCommand
    /// External process and an unconfirmed command: one dialog covers both.
    case confirmCommandAndReplace(pid: Int32, command: String)

    static func next(status: ServiceStatus?, approval: ServiceApproval.Status) -> ServiceRestartFlow {
        let approved = approval == .approved
        switch status ?? .stopped {
        case .portBusy: return .none
        case .external(let pid, let command):
            return approved ? .confirmStopThenStart(pid: pid, command: command)
                : .confirmCommandAndReplace(pid: pid, command: command)
        case .running, .stopped:
            return approved ? .restartManaged : .confirmCommand
        }
    }
}
