import Foundation
import Observation

/// Registered services for the Services page. Watches the registry directory
/// only while the page is open (a 1 s listing check), so nothing runs in the
/// background otherwise.
@Observable
final class ServiceStore {
    static let watchInterval: TimeInterval = 1.0

    private(set) var items: [ServiceRegistryItem] = []
    private(set) var statuses: [String: ServiceStatus] = [:]
    /// Can each registration still run (directory and executable present)?
    private(set) var validity: [String: ServiceValidity] = [:]
    /// brew services and LaunchAgents shown below the registered list.
    private(set) var systemServices: [SystemService] = []
    @ObservationIgnored private var brewItems: [BrewServices.Item] = []
    @ObservationIgnored private var lastBrewRead = Date.distantPast
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Reads brew (every 10 s) and launchd state (every refresh); read-only.
    func refreshSystemServices() {
        let readBrew = Date().timeIntervalSince(lastBrewRead) >= 10
        if readBrew { lastBrewRead = Date() }
        let cachedBrew = brewItems
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let brew = readBrew ? (BrewServices.list() ?? cachedBrew) : cachedBrew
            let services = SystemServiceCatalog.build(brew: brew)
            DispatchQueue.main.async {
                self?.brewItems = brew
                self?.systemServices = services
            }
        }
    }

    func perform(_ action: SystemServiceAction, on service: SystemService) {
        errors[service.id] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = SystemServiceActions.perform(action, on: service)
            DispatchQueue.main.async {
                self?.errors[service.id] = failure
                self?.lastBrewRead = .distantPast
                self?.refreshSystemServices()
            }
        }
    }

    /// Only after the user confirmed in the autostart dialog.
    func setAutostart(_ enable: Bool, on service: SystemService) {
        errors[service.id] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = SystemServiceActions.setAutostart(enable, on: service)
            DispatchQueue.main.async {
                self?.errors[service.id] = failure
                self?.lastBrewRead = .distantPast
                self?.refreshSystemServices()
            }
        }
    }

    /// Reads launchd state off the main thread; read-only.
    func refreshStatus() {
        refreshSystemServices()
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
        // A changed command can be confirmed while our old job still runs.
        if launcher.runningPID(id: entry.id) != nil {
            restartManaged(entry)
        } else {
            start(entry)
        }
    }

    /// Only called from the confirmation sheet that named the running process:
    /// records the approval, ends that process, then starts the service.
    func approveAndReplace(_ entry: ServiceEntry, pid: Int32, command: String) {
        approvals.approve(entry)
        terminateExternal(pid: pid, expectedCommand: command, thenStart: entry)
    }

    /// Stops our own job and starts it again once the old process has exited,
    /// so the new one never races it for the port.
    func restartManaged(_ entry: ServiceEntry) {
        errors[entry.id] = nil
        let launcher = self.launcher
        let oldPID = launcher.runningPID(id: entry.id)
        launcher.stop(id: entry.id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let oldPID {
                // launchd sends SIGTERM on removal and SIGKILL after its 20 s exit timeout.
                let deadline = Date().addingTimeInterval(25)
                while kill(oldPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            }
            DispatchQueue.main.async { self?.start(entry) }
        }
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
                DispatchQueue.main.async {
                    if let entry { self?.errors[entry.id] = t("services.error.process_changed") }
                    self?.refreshSoon()
                }
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
        checkValidity()
    }

    /// Spawns a login shell per command, so it runs only on page open and file changes.
    private func checkValidity() {
        let entries = items.compactMap { item -> ServiceEntry? in
            if case .valid(let e) = item.state { return e }
            return nil
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, ServiceValidity.check($0)) })
            DispatchQueue.main.async { self?.validity = result }
        }
    }

    /// Moves the registration file to the Trash. Refused while the service runs.
    @discardableResult
    func delete(_ item: ServiceRegistryItem) -> Bool {
        if statuses[item.id]?.isRunning == true { return false }
        do {
            try ServiceRegistry.moveToTrash(item.fileURL)
        } catch {
            errors[item.id] = error.localizedDescription
            return false
        }
        reload()
        return true
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
