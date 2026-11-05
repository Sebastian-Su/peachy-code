import Foundation
import Observation

/// Registered services for the Services page. Watches the registry directory
/// only while the page is open (a 1 s listing check), so nothing runs in the
/// background otherwise.
@Observable
final class ServiceStore {
    private(set) var items: [ServiceRegistryItem] = []
    private(set) var statuses: [String: ServiceStatus] = [:]
    /// Last run of each `task` registration.
    private(set) var taskRuns: [String: TaskRun] = [:]
    /// Last start error per service id, shown under the row.
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored let directory: URL
    @ObservationIgnored let launcher: ServiceLauncher
    @ObservationIgnored let approvals: ServiceApproval
    @ObservationIgnored let runStore: TaskRunStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var signature = ""

    init(directory: URL = ServiceRegistry.defaultDirectory,
         launcher: ServiceLauncher = .shared,
         approvals: ServiceApproval = .shared,
         runStore: TaskRunStore = .shared) {
        self.directory = directory
        self.launcher = launcher
        self.approvals = approvals
        self.runStore = runStore
    }

    func startWatching() {
        reload()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Reads launchd state off the main thread; read-only.
    func refreshStatus() {
        let entries = items.compactMap { item -> ServiceEntry? in
            if case .valid(let e) = item.state { return e }
            return nil
        }
        let launcher = self.launcher
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ports = entries.contains { $0.port != nil } ? PortListener.listeningPorts() : [:]
            var described: [Int32: PortListener] = [:]
            var result: [String: ServiceStatus] = [:]
            for entry in entries {
                var managed: Int32?
                if case .running(let pid) = ServiceRunState.read(entry, launcher: launcher) { managed = pid }
                var listener: PortListener?
                if managed == nil, let port = entry.port, let pid = ports[port] {
                    listener = described[pid] ?? PortListener.describe(pid: pid)
                    described[pid] = listener
                }
                result[entry.id] = ServiceStatus.resolve(entry, managedPID: managed, listener: listener)
            }
            // Finished tasks: record exit code once, then remove the exited job.
            var finished: [String: Int32?] = [:]
            for entry in entries where entry.kind == .task && !(result[entry.id]?.isRunning ?? false) {
                finished[entry.id] = launcher.lastExitStatus(id: entry.id)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statuses = result
                for (id, exit) in finished { self.observeTaskFinished(id: id, lastExit: exit) }
            }
        }
    }

    private func observeTaskFinished(id: String, lastExit: Int32?) {
        guard let run = taskRuns[id] ?? runStore.run(for: id) else { return }
        let (next, cleanUp) = run.observe(running: false, lastExit: lastExit, now: Date())
        taskRuns[id] = next
        if cleanUp {
            runStore.set(next, for: id)
            launcher.stop(id: id)
        }
    }

    func loadTaskRuns() {
        for item in items { if let run = runStore.run(for: item.id) { taskRuns[item.id] = run } }
    }

    func approvalStatus(of entry: ServiceEntry) -> ServiceApproval.Status { approvals.status(of: entry) }

    /// Only called from the confirmation sheet: records the approval, then starts.
    func approveAndStart(_ entry: ServiceEntry) {
        approvals.approve(entry)
        start(entry)
    }

    func start(_ entry: ServiceEntry) {
        errors[entry.id] = nil
        if entry.kind == .task {
            guard TaskRun.canExecute(status: statuses[entry.id]) else { return }
        }
        do {
            try launcher.start(entry)
            if entry.kind == .task {
                let run = TaskRun(startedAt: Date(), finishedAt: nil, exitCode: nil)
                taskRuns[entry.id] = run
                runStore.set(run, for: entry.id)
                statuses[entry.id] = .running(pid: 0)
            }
        } catch ServiceLauncher.LaunchError.launchctlFailed(let output) {
            errors[entry.id] = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            errors[entry.id] = "\(error)"
        }
        refreshSoon()
    }

    func stop(_ entry: ServiceEntry) {
        launcher.stop(id: entry.id)
        refreshSoon()
    }

    /// Only after the user confirmed the exact process (pid and command line).
    /// Re-checks that the same pid still runs the same command before signalling.
    func terminateExternal(pid: Int32, expectedCommand: String, thenStart entry: ServiceEntry? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let current = PortListener.describe(pid: pid).command
            guard current == expectedCommand else {
                DispatchQueue.main.async { self?.refreshSoon() }
                return
            }
            ProcessTerminator.terminate(pid: pid)
            DispatchQueue.main.async {
                if let entry { self?.start(entry) } else { self?.refreshSoon() }
            }
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshStatus() }
    }

    func reload() {
        signature = currentSignature()
        items = ServiceRegistry.load(from: directory)
        loadTaskRuns()
    }

    func reloadIfChanged() {
        if currentSignature() != signature { reload(); refreshStatus() }
    }

    /// File names plus modification times: cheap to compute every second.
    private func currentSignature() -> String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.pathExtension == "json" }.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "\(url.lastPathComponent):\(date?.timeIntervalSince1970 ?? 0)"
        }.sorted().joined(separator: "|")
    }
}
