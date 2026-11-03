import SwiftUI

/// One newest-first timeline of notifications, approval records and activity
/// events. ↑↓ moves the selection, U marks the selected notification read.
struct InboxView: View {
    @Environment(AppStore.self) var appStore
    @Environment(ViewClock.self) var clock
    @State private var projectFilter: String?
    @State private var selectedId: UUID?
    @State private var expandedRuns: Set<UUID> = []
    @State private var showClearAllConfirmation = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let _ = clock.tick
        let data = InboxData(appStore: appStore)
        let entries = InboxHistory.build(data.sources, project: projectFilter)

        VStack(spacing: 0) {
            header(projects: data.projects)
            Divider().overlay(Constants.border)
            if entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                row(for: entry, data: data)
                                    .id(entry.id)
                                Divider().overlay(Constants.border).padding(.leading, 16)
                            }
                        }
                    }
                    .onChange(of: selectedId) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(.downArrow) { move(1, in: entries); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: entries); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "uU")) { _ in
                    if let id = selectedId { appStore.notificationStore.markAsRead(id) }
                    return .handled
                }
            }
        }
        .background(Constants.lightBackground)
        .onAppear { isFocused = true }
        .overlay {
            if showClearAllConfirmation {
                ClearAllConfirmationDialog(
                    onConfirm: {
                        appStore.notificationStore.clearAll()
                        showClearAllConfirmation = false
                    },
                    onCancel: { showClearAllConfirmation = false }
                )
            }
        }
    }

    // MARK: - Header

    private func header(projects: [String]) -> some View {
        let hasUnread = appStore.notificationStore.unreadCount > 0
        let isEmpty = appStore.notificationStore.notifications.isEmpty
        return HStack(spacing: 12) {
            Text(t("inbox.history"))
                .font(Constants.heading(size: 15, weight: .bold))
                .foregroundColor(Constants.textPrimary)
            Picker("", selection: $projectFilter) {
                Text(t("inbox.all_projects")).tag(String?.none)
                ForEach(projects, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button(t("notifications.mark_read")) { appStore.notificationStore.markAllAsRead() }
                .buttonStyle(.plain)
                .font(Constants.body(size: 13, weight: .medium))
                .foregroundColor(hasUnread ? Constants.accentText : Constants.textMuted)
                .disabled(!hasUnread)
            Button(t("notifications.clear")) { showClearAllConfirmation = true }
                .buttonStyle(.plain)
                .font(Constants.body(size: 13, weight: .medium))
                .foregroundColor(isEmpty ? Constants.textMuted : Constants.destructiveRed)
                .disabled(isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(Constants.textMuted)
            Text(t("notifications.empty"))
                .font(Constants.heading(size: 20, weight: .bold))
                .foregroundColor(Constants.textPrimary)
            Text(t("notifications.hint"))
                .font(Constants.body(size: 14))
                .foregroundColor(Constants.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for entry: InboxHistory.Entry, data: InboxData) -> some View {
        switch entry {
        case .single(let source):
            switch source.kind {
            case .notification:
                if let notification = data.notifications[source.id] {
                    selectable(source.id) {
                        NotificationRow(notification: notification, project: source.project)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    } onTap: {
                        appStore.notificationStore.markAsRead(notification.id)
                    }
                }
            case .approval:
                if let record = data.approvals[source.id] {
                    selectable(source.id) { HistoryApprovalRow(record: record) }
                }
            case .activity:
                EmptyView()
            }
        case .activityRun(let run):
            activityRun(run, data: data)
        }
    }

    private func activityRun(_ run: [InboxHistory.Source], data: InboxData) -> some View {
        let runId = run[0].id
        let isExpanded = expandedRuns.contains(runId)
        let events = run.compactMap { data.events[$0.id] }
        let names = Array(NSOrderedSet(array: events.map { $0.eventType?.displayName ?? $0.hookEventName })) as? [String] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            selectable(runId) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Constants.textMuted)
                        .frame(width: 24)
                    Text(String(format: t("inbox.activity_run"), run.count))
                        .font(Constants.body(size: 13, weight: .medium))
                        .foregroundColor(Constants.textMuted)
                    Text(names.prefix(3).joined(separator: " · "))
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(1)
                    Spacer()
                    if let latest = events.first {
                        Text(relativeTimeString(from: latest.receivedAt))
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } onTap: {
                if isExpanded { expandedRuns.remove(runId) } else { expandedRuns.insert(runId) }
            }
            if isExpanded {
                ForEach(events) { event in
                    EventRow(event: event)
                        .padding(.leading, 40)
                        .padding(.trailing, 16)
                }
            }
        }
    }

    private func selectable<Content: View>(
        _ id: UUID,
        @ViewBuilder content: () -> Content,
        onTap: @escaping () -> Void = {}
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedId == id ? Constants.orangePrimarySubtle : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedId = id
                isFocused = true
                onTap()
            }
    }

    private func move(_ step: Int, in entries: [InboxHistory.Entry]) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selectedId }
        let next = current.map { min(max($0 + step, 0), entries.count - 1) } ?? 0
        selectedId = entries[next].id
    }
}

/// Lookup tables for one render of the inbox.
private struct InboxData {
    let notifications: [UUID: AppNotification]
    let approvals: [UUID: ApprovalRecord]
    let events: [UUID: AgentEvent]
    let sources: [InboxHistory.Source]
    let projects: [String]

    init(appStore: AppStore) {
        let projectBySession = Dictionary(
            appStore.sessionStore.sessions.compactMap { s in s.projectName.map { (s.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let notifications = appStore.notificationStore.notifications
        let approvals = appStore.approvalHistoryStore.history
        let events = appStore.eventStore.events
        self.notifications = Dictionary(notifications.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.approvals = Dictionary(approvals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.events = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sources: [InboxHistory.Source] = []
        sources.reserveCapacity(notifications.count + approvals.count + events.count)
        for n in notifications {
            sources.append(.init(id: n.id, date: n.createdAt, kind: .notification, project: n.sessionId.flatMap { projectBySession[$0] }))
        }
        for a in approvals {
            sources.append(.init(id: a.id, date: a.createdAt, kind: .approval, project: a.projectName))
        }
        for e in events {
            sources.append(.init(id: e.id, date: e.receivedAt, kind: .activity, project: e.projectName))
        }
        self.sources = sources
        self.projects = Array(Set(sources.compactMap(\.project))).sorted()
    }
}
