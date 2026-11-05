import Foundation
import Observation

/// Registered services for the Services page. Watches the registry directory
/// only while the page is open (a 1 s listing check), so nothing runs in the
/// background otherwise.
@Observable
final class ServiceStore {
    private(set) var items: [ServiceRegistryItem] = []
    private(set) var runStates: [String: ServiceRunState] = [:]
    /// Last start error per service id, shown under the row.
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored let directory: URL
    @ObservationIgnored let launcher: ServiceLauncher
    @ObservationIgnored let approvals: ServiceApproval
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var signature = ""

    init(directory: URL = ServiceRegistry.defaultDirectory,
         launcher: ServiceLauncher = .shared,
         approvals: ServiceApproval = .shared) {
        self.directory = directory
        self.launcher = launcher
        self.approvals = approvals
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
            let states = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, ServiceRunState.read($0, launcher: launcher)) })
            DispatchQueue.main.async { self?.runStates = states }
        }
    }

    func approvalStatus(of entry: ServiceEntry) -> ServiceApproval.Status { approvals.status(of: entry) }

    /// Only called from the confirmation sheet: records the approval, then starts.
    func approveAndStart(_ entry: ServiceEntry) {
        approvals.approve(entry)
        start(entry)
    }

    func start(_ entry: ServiceEntry) {
        errors[entry.id] = nil
        do {
            try launcher.start(entry)
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

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshStatus() }
    }

    func reload() {
        signature = currentSignature()
        items = ServiceRegistry.load(from: directory)
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
