import Foundation

/// One run of a `task` registration: when it started, and once it is seen
/// finished, how it ended.
struct TaskRun: Codable, Equatable {
    var startedAt: Date
    var finishedAt: Date?
    var exitCode: Int32?

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    static func canExecute(status: ServiceStatus?) -> Bool {
        !(status?.isRunning ?? false)
    }

    /// Applies one status reading. The first reading after the job stops
    /// records the result and asks for the finished job to be removed.
    func observe(running: Bool, lastExit: Int32?, now: Date) -> (run: TaskRun, cleanUp: Bool) {
        guard finishedAt == nil, !running else { return (self, false) }
        var done = self
        done.finishedAt = now
        done.exitCode = lastExit
        return (done, true)
    }
}

/// Last run per task id, in PeachyPet's own defaults.
final class TaskRunStore {
    static let shared = TaskRunStore()
    private static let key = "serviceTaskRuns"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var all: [String: TaskRun] {
        guard let data = defaults.data(forKey: Self.key),
              let runs = try? JSONDecoder().decode([String: TaskRun].self, from: data) else { return [:] }
        return runs
    }

    func run(for id: String) -> TaskRun? { all[id] }

    func set(_ run: TaskRun, for id: String) {
        var runs = all
        runs[id] = run
        if let data = try? JSONEncoder().encode(runs) { defaults.set(data, forKey: Self.key) }
    }
}
