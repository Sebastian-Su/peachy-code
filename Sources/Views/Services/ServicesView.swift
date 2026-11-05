import SwiftUI

/// Registered start commands plus brew services and LaunchAgents.
struct ServicesView: View {
    @Environment(AppStore.self) var appStore

    var body: some View {
        let store = appStore.serviceStore
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(t("services.section.registered"), count: store.items.count)
                if store.items.isEmpty {
                    Text(t("services.empty"))
                        .font(Constants.body(size: 13))
                        .foregroundColor(Constants.textMuted)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                }
                ForEach(store.items) { item in
                    ServiceRow(item: item, runState: store.runStates[item.id], error: store.errors[item.id],
                               approval: approval(of: item, store: store)) { action in
                        handle(action, store: store)
                    }
                }
            }
            .padding(20)
        }
        .background(Constants.lightBackground)
        .onAppear { store.startWatching() }
        .onDisappear { store.stopWatching() }
        .sheet(item: $pendingApproval) { entry in
            ServiceApprovalSheet(entry: entry, status: store.approvalStatus(of: entry)) {
                store.approveAndStart(entry)
                pendingApproval = nil
            } onCancel: {
                pendingApproval = nil
            }
        }
    }

    @State private var pendingApproval: ServiceEntry?

    private func approval(of item: ServiceRegistryItem, store: ServiceStore) -> ServiceApproval.Status {
        if case .valid(let entry) = item.state { return store.approvalStatus(of: entry) }
        return .approved
    }

    private func handle(_ action: ServiceRow.Action, store: ServiceStore) {
        switch action {
        case .start(let entry):
            if store.approvalStatus(of: entry) == .approved {
                store.start(entry)
            } else {
                pendingApproval = entry
            }
        case .stop(let entry):
            store.stop(entry)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(Constants.body(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundColor(Constants.textMuted)
    }
}

struct ServiceRow: View {
    enum Action {
        case start(ServiceEntry)
        case stop(ServiceEntry)
    }

    @State private var showLog = false
    @State private var logText = ""

    let item: ServiceRegistryItem
    var runState: ServiceRunState? = nil
    var error: String? = nil
    var approval: ServiceApproval.Status = .approved
    var onAction: (Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainRow
            if showLog {
                ScrollView {
                    Text(logText.isEmpty ? t("services.log.empty") : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Constants.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(8)
                .background(Constants.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
        .task(id: showLog) {
            guard showLog else { return }
            while !Task.isCancelled && showLog {
                logText = ServiceLog.tail(ServiceLauncher.logURL(for: item.id), lines: 200)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(Constants.heading(size: 15, weight: .bold))
                        .foregroundColor(Constants.textPrimary)
                    if case .valid(let entry) = item.state {
                        Text(entry.kind == .service ? t("services.kind.service") : t("services.kind.task"))
                            .font(Constants.body(size: 11, weight: .medium))
                            .foregroundColor(Constants.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Constants.chip, in: Capsule())
                    }
                }
                switch item.state {
                case .valid(let entry):
                    if let note = entry.note {
                        Text(note).font(Constants.body(size: 12)).foregroundColor(Constants.textMuted)
                    }
                    Text(entry.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error {
                        Text(error).font(Constants.body(size: 11)).foregroundColor(Constants.destructiveRed).lineLimit(2)
                    }
                case .invalid(let reason):
                    Text(t("services.format_error") + " · " + reason.message)
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.destructiveRed)
                }
            }
            Spacer()
            if case .valid(let entry) = item.state {
                HStack(spacing: 8) {
                    if let url = entry.url {
                        Button(t("services.open")) { NSWorkspace.shared.open(url) }
                            .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    }
                    Button(showLog ? t("services.log.hide") : t("services.log.show")) { showLog.toggle() }
                        .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                    if entry.kind == .service { controls(for: entry) }
                }
            }
        }
    }

    @ViewBuilder
    private func controls(for entry: ServiceEntry) -> some View {
        HStack(spacing: 8) {
            statusBadge
            switch runState ?? .stopped {
            case .running:
                Button(t("services.stop")) { onAction(.stop(entry)) }
                    .buttonStyle(BrandGhostButton(color: Constants.textMuted))
            case .stopped:
                Button(startTitle) { onAction(.start(entry)) }
                    .buttonStyle(BrandGhostButton(color: Constants.accentText))
            }
        }
    }

    private var startTitle: String {
        approval == .approved ? t("services.start") : t("services.confirm_and_start")
    }

    private var statusBadge: some View {
        let running: Bool = { if case .running = runState { return true }; return false }()
        let color = running ? Color(.sRGB, red: 22/255, green: 140/255, blue: 70/255) : Constants.textMuted
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(running ? t("services.running") : t("services.stopped"))
                .font(Constants.body(size: 11, weight: .medium))
                .foregroundColor(color)
        }
    }

    private var title: String {
        if case .valid(let entry) = item.state { return entry.name }
        return item.id
    }

    private var icon: String {
        switch item.state {
        case .valid(let entry): entry.kind == .service ? "server.rack" : "play.square"
        case .invalid: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        if case .invalid = item.state { return Constants.destructiveRed }
        return Constants.accentText
    }
}
