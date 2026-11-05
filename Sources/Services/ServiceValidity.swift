import Foundation

/// Whether a registration can still run. Only checks that the working
/// directory exists and the first executable can be found; dependencies are
/// not inspected.
enum ServiceValidity: Equatable {
    case ok
    case missingDirectory(String)
    case commandNotFound(String)

    var message: String? {
        switch self {
        case .ok: nil
        case .missingDirectory(let path): String(format: t("services.invalid.dir"), path)
        case .commandNotFound(let name): String(format: t("services.invalid.command"), name)
        }
    }

    static func check(_ entry: ServiceEntry, resolves: (String) -> Bool = ServiceValidity.resolvesInLoginShell) -> ServiceValidity {
        var isDir: ObjCBool = false
        if let cwd = entry.cwd, !(FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue) {
            return .missingDirectory(cwd)
        }
        guard let exe = firstExecutable(entry.command) else { return .ok }
        if exe.contains("/") {
            let path = exe.hasPrefix("/") ? exe
                : URL(fileURLWithPath: entry.cwd ?? NSHomeDirectory()).appendingPathComponent(exe).standardizedFileURL.path
            return FileManager.default.fileExists(atPath: path) ? .ok : .commandNotFound(path)
        }
        return resolves(exe) ? .ok : .commandNotFound(exe)
    }

    /// First word that names a program: skips `VAR=value` assignments and `exec`/`env`.
    static func firstExecutable(_ command: String) -> String? {
        for token in command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if token.contains("=") && !token.hasPrefix("/") && !token.hasPrefix(".") { continue }
            if ["exec", "env", "nohup", "command"].contains(token) { continue }
            return ServiceRegistry.expandTilde(token)
        }
        return nil
    }

    /// `command -v` in the user's login shell, so conda/fnm/brew PATHs count. Read-only.
    static func resolvesInLoginShell(_ name: String) -> Bool {
        guard name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ServiceLauncher.loginShell)
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

extension ServiceRegistry {
    /// Deletion moves the registration to the Trash so it can be recovered.
    @discardableResult
    static func moveToTrash(_ file: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &result)
        return result as URL?
    }
}
