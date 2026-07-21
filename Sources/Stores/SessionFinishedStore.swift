import Foundation

@Observable
final class SessionFinishedStore {
    var current: Toast? = nil
    var onDismiss: (() -> Void)?
    private var dismissTimer: Timer?

    static let enabledKey = "taskCompletedToastEnabled"
    static let durationKey = "taskCompletedToastDuration"
    static let defaultDuration: TimeInterval = 8

    struct Toast {
        let sessionId: String
        let projectName: String
        let duration: TimeInterval
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    var toastDuration: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.durationKey)
            return stored > 0 ? stored : Self.defaultDuration
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.durationKey) }
    }

    func show(sessionId: String, projectName: String) {
        guard isEnabled else { return }
        let duration = toastDuration
        current = Toast(sessionId: sessionId, projectName: projectName, duration: duration)
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    func dismiss() {
        guard current != nil else { return }
        current = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        onDismiss?()
    }
}
