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

    static func resolve(_ entry: ServiceEntry, managedPID: Int32?, listener: PortListener?) -> ServiceStatus {
        if let managedPID { return .running(pid: managedPID) }
        guard let listener else { return .stopped }
        return matches(entry, listener)
            ? .external(pid: listener.pid, command: listener.command)
            : .portBusy(pid: listener.pid, command: listener.command)
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
