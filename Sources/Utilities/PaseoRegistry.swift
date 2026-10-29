import Foundation

/// Sessions started from Paseo (sh.paseo.desktop). Paseo drives Codex through app-server, so
/// their rollouts say `source: vscode` and look like Codex Desktop. Paseo keeps one record per
/// agent in `~/.paseo/agents/<project>/<agentId>.json` whose `runtimeInfo.sessionId` is the
/// Codex/Claude session id; it is written before the session starts.
final class PaseoRegistry {
    static let bundleId = "sh.paseo.desktop"

    static let shared: PaseoRegistry = {
        let isRunningTests = NSClassFromString("XCTestCase") != nil
        let root = isRunningTests
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PeachyPetTests-no-paseo")
            : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".paseo")
        return PaseoRegistry(root: root)
    }()

    struct Agent: Equatable {
        let serverId: String
        let agentId: String

        /// Paseo's agent link (packages/protocol/src/agent-deep-link.ts).
        var deepLink: URL? {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            guard let server = serverId.addingPercentEncoding(withAllowedCharacters: allowed),
                  let agent = agentId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return URL(string: "paseo://h/\(server)/agent/\(agent)")
        }
    }

    private let root: URL
    private var agentsBySession: [String: Agent] = [:]
    /// Parsed records by path, kept while the file's modification date is unchanged:
    /// a rescan then only stats files (a full parse of ~90 records took 22 ms on main).
    private var records: [URL: (modified: Date, agentId: String, sessionId: String)] = [:]
    private var lastScan: Date?
    /// A miss rescans at most this often; session rows ask on every render.
    private let rescanInterval: TimeInterval = 5

    init(root: URL) {
        self.root = root
    }

    func agent(forSession sessionId: String) -> Agent? {
        if let agent = agentsBySession[sessionId] { return agent }
        if let lastScan, Date().timeIntervalSince(lastScan) < rescanInterval { return nil }
        scan()
        return agentsBySession[sessionId]
    }

    private func scan() {
        lastScan = Date()
        let fm = FileManager.default
        guard let serverId = try? String(contentsOf: root.appendingPathComponent("server-id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !serverId.isEmpty,
            let projects = try? fm.contentsOfDirectory(at: root.appendingPathComponent("agents"), includingPropertiesForKeys: nil)
        else {
            records = [:]
            agentsBySession = [:]
            return
        }
        var found: [String: Agent] = [:]
        var seen: [URL: (modified: Date, agentId: String, sessionId: String)] = [:]
        for project in projects {
            let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "json" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                let record: (modified: Date, agentId: String, sessionId: String)
                if let cached = records[file], cached.modified == modified {
                    record = cached
                } else {
                    guard let data = try? Data(contentsOf: file),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let agentId = json["id"] as? String,
                          let runtime = json["runtimeInfo"] as? [String: Any],
                          let sessionId = runtime["sessionId"] as? String else { continue }
                    record = (modified, agentId, sessionId)
                }
                seen[file] = record
                found[record.sessionId] = Agent(serverId: serverId, agentId: record.agentId)
            }
        }
        records = seen
        agentsBySession = found
    }
}
