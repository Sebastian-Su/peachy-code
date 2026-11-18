import Foundation

struct SessionResultTool {
    struct Output {
        let markdown: String
        let sessionID: String?
    }

    enum Backend: String, CaseIterable, Hashable {
        case codex, executable
    }

    enum Failure: Error {
        case executableMissing
        case unsuccessfulExit(Int32)
        case emptyOutput
        case missingSessionID
    }

    let backend: Backend
    let executablePath: String
    let workingDirectory: URL

    static var defaultWorkingDirectory: URL {
        LocalStorage.appSupportDir.appendingPathComponent("Session Result Tool", isDirectory: true)
    }

    static func isWorkerDirectory(_ path: String?) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == defaultWorkingDirectory.standardizedFileURL.path
    }

    func run(prompt: String, sessionID: String?, retainSession: Bool) async throws -> Output {
        try await Task.detached(priority: .utility) {
            try runProcess(prompt: prompt, sessionID: sessionID, retainSession: retainSession)
        }.value
    }

    // Use files for stdio so even large Markdown and JSONL cannot fill a pipe.
    private func runProcess(prompt: String, sessionID: String?, retainSession: Bool) throws -> Output {
        let fm = FileManager.default
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let scratch = fm.temporaryDirectory.appendingPathComponent("peachy-result-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }

        let inputURL = scratch.appendingPathComponent("input")
        let stdoutURL = scratch.appendingPathComponent("stdout")
        let resultURL = scratch.appendingPathComponent("result.md")
        try Data(prompt.utf8).write(to: inputURL)
        try Data().write(to: stdoutURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }

        let executable = try resolveExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        if backend == .codex {
            // Exec's top-level sandbox flag is unavailable on resume. Set its
            // equivalent config override for both forms.
            var arguments = [
                "exec", "--json", "--skip-git-repo-check",
                "--disable", "hooks", "--disable", "shell_tool", "--disable", "apps",
                "--disable", "multi_agent", "--disable", "multi_agent_v2",
                "-c", "mcp_servers={}", "-c", "web_search=\"disabled\"",
                "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"",
                "--output-last-message", resultURL.path,
            ]
            if !retainSession { arguments.append("--ephemeral") }
            if let sessionID { arguments.append(contentsOf: ["resume", sessionID]) }
            arguments.append("-")
            process.arguments = arguments
        } else {
            var environment = ProcessInfo.processInfo.environment
            environment["PEACHYPET_SESSION_ID"] = sessionID
            process.environment = environment
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unsuccessfulExit(process.terminationStatus) }

        let outputURL = backend == .codex ? resultURL : stdoutURL
        guard let markdown = try? String(contentsOf: outputURL, encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyOutput
        }
        let threadID = backend == .codex ? try Self.codexSessionID(in: stdoutURL) : sessionID
        if backend == .codex, let sessionID, threadID != sessionID {
            throw Failure.missingSessionID
        }
        return Output(markdown: markdown, sessionID: threadID)
    }

    private func resolveExecutable() throws -> String {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String]
        if backend == .codex && path.isEmpty {
            let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          NSHomeDirectory() + "/.local/bin/codex"]
                + searchPath.split(separator: ":").map { "\($0)/codex" }
        } else {
            candidates = [(path as NSString).expandingTildeInPath]
        }
        guard let executable = candidates.first(where: {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw Failure.executableMissing }
        return executable
    }

    private static func codexSessionID(in url: URL) throws -> String? {
        let stream = try String(contentsOf: url, encoding: .utf8)
        for line in stream.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                  event["type"] == "thread.started",
                  let thread = event["thread_id"], UUID(uuidString: thread) != nil else { continue }
            return thread
        }
        return nil
    }
}
