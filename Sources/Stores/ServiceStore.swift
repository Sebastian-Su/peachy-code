import Foundation
import Observation

/// Registered services for the Services page. Watches the registry directory
/// only while the page is open (a 1 s listing check), so nothing runs in the
/// background otherwise.
@Observable
final class ServiceStore {
    private(set) var items: [ServiceRegistryItem] = []
    @ObservationIgnored let directory: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var signature = ""

    init(directory: URL = ServiceRegistry.defaultDirectory) {
        self.directory = directory
    }

    func startWatching() {
        reload()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reloadIfChanged() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        signature = currentSignature()
        items = ServiceRegistry.load(from: directory)
    }

    func reloadIfChanged() {
        if currentSignature() != signature { reload() }
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
