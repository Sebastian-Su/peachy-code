import Foundation

@Observable
final class SessionFinishedStore {
    var current: Toast? = nil
    var onDismiss: (() -> Void)?
    private var dismissTimer: Timer?

    static let enabledKey = "taskCompletedToastEnabled"
    static let durationKey = "taskCompletedToastDuration"
    static let defaultDuration: TimeInterval = 8

    enum Kind: Equatable {
        case completed
        case waitingInput
    }

    struct Toast {
        let id = UUID()
        let kind: Kind
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

    func show(kind: Kind, sessionId: String, projectName: String) {
        guard isEnabled else { return }
        // Repeated events for the same session/kind keep the existing card and timer
        // rather than resetting the countdown (e.g. duplicate idle_prompt notifications).
        if let current, current.kind == kind, current.sessionId == sessionId {
            return
        }
        let duration = toastDuration
        let toast = Toast(
            kind: kind,
            sessionId: sessionId,
            projectName: projectName,
            duration: duration
        )
        current = toast
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss(toastId: toast.id) }
        }
    }

    func dismiss(toastId: UUID) {
        guard current?.id == toastId else { return }
        dismiss()
    }

    func dismiss(sessionId: String) {
        guard current?.sessionId == sessionId else { return }
        dismiss()
    }

    func dismiss() {
        guard current != nil else { return }
        current = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        onDismiss?()
    }
}
