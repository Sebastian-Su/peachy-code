import Foundation

enum SessionResultTranscript {
    static func report(for event: AgentEvent) async throws -> String? {
        if let message = event.lastAssistantMessage,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        guard event.agentSource == .copilot, let id = event.sessionId,
              UUID(uuidString: id) != nil, let path = event.transcriptPath else { return nil }

        let fm = FileManager.default
        let home = ProcessInfo.processInfo.environment["COPILOT_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".copilot", isDirectory: true)
        let expected = home.appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true).appendingPathComponent("events.jsonl")
        let transcript = URL(fileURLWithPath: path).standardizedFileURL
        guard transcript.path == expected.standardizedFileURL.path,
              transcript.resolvingSymlinksInPath().path
                == expected.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent("events.jsonl").path,
              try transcript.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }

        return try await Task.detached(priority: .utility) {
            try latestCopilotReply(at: transcript)
        }.value
    }

    static func latestCopilotReply(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        var partial = Data()
        while offset > 0 {
            let count = min(offset, 64 * 1024)
            offset -= count
            try handle.seek(toOffset: offset)
            var bytes = try handle.read(upToCount: Int(count)) ?? Data()
            bytes.append(partial)
            let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            partial = offset > 0 ? Data(lines.first ?? Data.SubSequence()) : Data()
            for line in (offset > 0 ? lines.dropFirst() : lines[...]).reversed() where !line.isEmpty {
                guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if record["type"] as? String == "user.message" { return nil }
                guard record["type"] as? String == "assistant.message",
                      let data = record["data"] as? [String: Any],
                      (data["toolRequests"] as? [Any])?.isEmpty != false else { continue }
                guard let content = data["content"] as? String,
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return content
            }
        }
        return nil
    }
}
