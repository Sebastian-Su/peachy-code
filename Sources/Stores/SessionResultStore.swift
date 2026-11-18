import Foundation

@Observable
final class SessionResultStore {
    static let historyRange = 1...1000
    static let defaultHistoryLimit = 100
    static let previewDuration: TimeInterval = 30

    enum Shortcut: Int {
        case readReport = 1
        case history = 2

        var label: String { "⌘\(rawValue)" }
    }

    struct Preview {
        let report: SessionResultReport
        var deadline: Date?
        var pausedFor: TimeInterval = 0

        func remaining(at time: Date) -> TimeInterval {
            deadline.map { max(0, $0.timeIntervalSince(time)) } ?? pausedFor
        }
    }

    struct Navigation: Equatable {
        let token = UUID()
        let reportID: UUID?
    }

    private(set) var preview: Preview?
    private(set) var entries: [SessionResultSource] = []
    private(set) var historyLimit: Int
    private(set) var historyUnavailable = false
    private(set) var navigation: Navigation?
    var onPreviewChange: (() -> Void)?
    var onHistoryOpen: (() -> Void)?

    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var pointerOverPreview = false
    @ObservationIgnored private var previewShortcutsHeld = false
    private let defaults: UserDefaults
    private let database: SessionResultHistory
    private let previewDuration: TimeInterval
    private static let limitKey = "sessionResult.historyLimit"

    init(defaults: UserDefaults = .standard,
         databaseURL: URL = LocalStorage.appSupportDir.appendingPathComponent("session-results.sqlite3"),
         previewDuration: TimeInterval = SessionResultStore.previewDuration) {
        self.defaults = defaults
        self.previewDuration = previewDuration
        let saved = defaults.object(forKey: Self.limitKey) as? Int ?? Self.defaultHistoryLimit
        let limit = Self.clampedLimit(saved)
        historyLimit = limit
        database = SessionResultHistory(url: databaseURL, limit: limit)
    }

    @MainActor func add(_ report: SessionResultReport, showPreview: Bool) async {
        do {
            try await database.append(report)
            await refresh()
        } catch {
            historyUnavailable = true
            PeachyLog.event.error("Could not save session result history: \(String(describing: error), privacy: .public)")
        }
        guard showPreview else { return }
        if let preview, preview.deadline == nil { return }
        preview = Preview(report: report, deadline: Date().addingTimeInterval(previewDuration))
        scheduleExpiry()
        onPreviewChange?()
    }

    @MainActor func refresh() async {
        do {
            entries = try await database.list()
            historyUnavailable = false
        } catch {
            historyUnavailable = true
        }
    }

    @MainActor func setHistoryLimit(_ value: Int) async {
        let limit = Self.clampedLimit(value)
        do {
            try await database.setLimit(limit)
            historyLimit = limit
            defaults.set(limit, forKey: Self.limitKey)
            await refresh()
        } catch {
            historyUnavailable = true
        }
    }

    @MainActor func report(id: UUID) async -> SessionResultReport? {
        do {
            return try await database.record(id: id)
        } catch {
            historyUnavailable = true
            return nil
        }
    }

    @MainActor func openHistory(reportID: UUID? = nil) {
        dismissPreview()
        navigation = Navigation(reportID: reportID)
        onHistoryOpen?()
    }

    @MainActor func perform(_ shortcut: Shortcut) {
        switch shortcut {
        case .readReport:
            guard let reportID = preview?.report.source.id else { return }
            openHistory(reportID: reportID)
        case .history:
            openHistory()
        }
    }

    @MainActor func setPreviewHovered(_ hovered: Bool, at time: Date = Date()) {
        pointerOverPreview = hovered
        updatePreviewPause(at: time)
    }

    @MainActor func setPreviewShortcutsHeld(_ held: Bool, at time: Date = Date()) {
        previewShortcutsHeld = held
        updatePreviewPause(at: time)
    }

    @MainActor private func updatePreviewPause(at time: Date) {
        let paused = pointerOverPreview || previewShortcutsHeld
        guard var preview else { return }
        if paused, preview.deadline != nil {
            preview.pausedFor = preview.remaining(at: time)
            preview.deadline = nil
        } else if !paused, preview.deadline == nil {
            preview.deadline = time.addingTimeInterval(preview.pausedFor)
        } else {
            return
        }
        self.preview = preview
        scheduleExpiry()
    }

    @MainActor func expirePreview(at time: Date = Date()) {
        guard let deadline = preview?.deadline, deadline <= time else { return }
        dismissPreview()
    }

    @MainActor func dismissPreview() {
        guard preview != nil else { return }
        preview = nil
        pointerOverPreview = false
        previewShortcutsHeld = false
        expiryTask?.cancel()
        expiryTask = nil
        onPreviewChange?()
    }

    @MainActor private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = preview?.deadline else {
            expiryTask = nil
            return
        }
        expiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            } catch {
                return
            }
            self?.expirePreview()
        }
    }

    private static func clampedLimit(_ limit: Int) -> Int {
        min(historyRange.upperBound, max(historyRange.lowerBound, limit))
    }
}
