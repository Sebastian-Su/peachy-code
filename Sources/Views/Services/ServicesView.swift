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
                registeredList(store: store)
                systemSection(t("services.section.brew"), store.systemServices.filter { $0.group == .brew }, store: store)
            }
            .padding(20)
        }
        .background(Constants.lightBackground)
        .onAppear { store.startWatching() }
        .onDisappear { store.stopWatching() }
        .modifier(ServiceDialogs(store: store, pendingApproval: $pendingApproval, pendingExternalStop: $pendingExternalStop,
                                 pendingDelete: $pendingDelete, deleteBlocked: $deleteBlocked))
    }

    @ViewBuilder
    private func systemSection(_ title: String, _ services: [SystemService], store: ServiceStore) -> some View {
        if !services.isEmpty {
            sectionHeader(title, count: services.count).padding(.top, 10)
            ForEach(services) { service in
                SystemServiceRow(service: service, error: store.errors[service.id]) { action in
                    store.perform(action, on: service)
                }
            }
        }
    }

    @ViewBuilder
    private func registeredList(store: ServiceStore) -> some View {
        ForEach(store.items) { item in
            ServiceRow(item: item, status: store.statuses[item.id], error: store.errors[item.id],
                       approval: approval(of: item, store: store),
                       taskRun: store.taskRuns[item.id],
                       validity: store.validity[item.id] ?? .ok) { action in
                handle(action, store: store)
            }
        }
    }

    @State private var pendingApproval: ServiceEntry?
    @State private var pendingExternalStop: ExternalStopRequest?
    @State private var pendingDelete: ServiceRegistryItem?
    @State private var deleteBlocked = false

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
            switch store.statuses[entry.id] {
            case .external(let pid, let command):
                pendingExternalStop = ExternalStopRequest(entry: entry, pid: pid, command: command, restart: false)
            default:
                store.stop(entry)
            }
        case .delete(let item):
            if store.statuses[item.id]?.isRunning == true {
                deleteBlocked = true
            } else {
                pendingDelete = item
            }
        case .restart(let entry):
            switch store.statuses[entry.id] {
            case .external(let pid, let command):
                // Restarting hands the service to PeachyPet; an unapproved command
                // still goes through the approval sheet afterwards.
                if store.approvalStatus(of: entry) == .approved {
                    pendingExternalStop = ExternalStopRequest(entry: entry, pid: pid, command: command, restart: true)
                } else {
                    pendingApproval = entry
                }
            default:
                store.stop(entry)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { handle(.start(entry), store: store) }
            }
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
        case restart(ServiceEntry)
        case delete(ServiceRegistryItem)
    }

    @State private var showLog = false
    @State private var logText = ""

    let item: ServiceRegistryItem
    var status: ServiceStatus? = nil
    var error: String? = nil
    var approval: ServiceApproval.Status = .approved
    var taskRun: TaskRun? = nil
    var validity: ServiceValidity = .ok
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
                    if let reason = validity.message {
                        Text(t("services.invalid") + " · " + reason)
                            .font(Constants.body(size: 12))
                            .foregroundColor(Constants.destructiveRed)
                    }
                    if entry.kind == .task, let run = taskRun, let finished = run.finishedAt {
                        let ok = run.exitCode == 0
                        Text(String(format: t("services.task.result"),
                                    run.exitCode.map(String.init) ?? "?",
                                    Self.durationText(run.duration ?? 0),
                                    relativeTimeString(from: finished)))
                            .font(Constants.body(size: 11, weight: .medium))
                            .foregroundColor(ok ? Color(.sRGB, red: 22/255, green: 140/255, blue: 70/255) : Constants.destructiveRed)
                        let tail = ServiceLog.tail(ServiceLauncher.logURL(for: entry.id), lines: 3)
                        if !tail.isEmpty {
                            Text(tail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Constants.textMuted)
                                .lineLimit(3)
                        }
                    }
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
                    if validity != .ok {
                        Button(t("services.delete")) { onAction(.delete(item)) }
                            .buttonStyle(BrandGhostButton(color: Constants.destructiveRed))
                    }
                    if entry.kind == .service { controls(for: entry) } else { taskControls(for: entry) }
                }
                .fixedSize()
            } else {
                Button(t("services.delete")) { onAction(.delete(item)) }
                    .buttonStyle(BrandGhostButton(color: Constants.destructiveRed))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func controls(for entry: ServiceEntry) -> some View {
        HStack(spacing: 8) {
            statusBadge
            switch status ?? .stopped {
            case .running, .external:
                Button(t("services.restart")) { onAction(.restart(entry)) }
                    .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                Button(t("services.stop")) { onAction(.stop(entry)) }
                    .buttonStyle(BrandGhostButton(color: Constants.textMuted))
            case .stopped:
                Button(startTitle) { onAction(.start(entry)) }
                    .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    .disabled(validity != .ok)
                    .opacity(validity != .ok ? 0.45 : 1)
            case .portBusy:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func taskControls(for entry: ServiceEntry) -> some View {
        let running = status?.isRunning ?? false
        HStack(spacing: 8) {
            if running {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass").font(.system(size: 11)).foregroundColor(Constants.textMuted)
                    Text(t("services.task.running")).font(Constants.body(size: 11, weight: .medium)).foregroundColor(Constants.textMuted)
                }
            }
            Button(approval == .approved ? t("services.task.execute") : t("services.confirm_and_start")) { onAction(.start(entry)) }
                .buttonStyle(BrandGhostButton(color: Constants.accentText))
                .disabled(!TaskRun.canExecute(status: status) || validity != .ok)
                .opacity(running || validity != .ok ? 0.45 : 1)
        }
    }

    private var startTitle: String {
        approval == .approved ? t("services.start") : t("services.confirm_and_start")
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            let green = Color(.sRGB, red: 22/255, green: 140/255, blue: 70/255)
            switch status ?? .stopped {
            case .running: return (t("services.running"), green)
            case .external: return (t("services.running_external"), green)
            case .portBusy: return (t("services.port_busy"), Constants.destructiveRed)
            case .stopped: return (t("services.stopped"), Constants.textMuted)
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Constants.body(size: 11, weight: .medium)).foregroundColor(color)
                .lineLimit(1).fixedSize()
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private var title: String {
        if case .valid(let entry) = item.state { return entry.name }
        return item.id
    }

    private var icon: String {
        switch item.state {
        case .valid where validity != .ok: "exclamationmark.triangle.fill"
        case .valid(let entry): entry.kind == .service ? "server.rack" : "play.square"
        case .invalid: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        if case .invalid = item.state { return Constants.destructiveRed }
        if validity != .ok { return Constants.destructiveRed }
        return Constants.accentText
    }
}

struct ExternalStopRequest: Identifiable {
    let entry: ServiceEntry
    let pid: Int32
    let command: String
    let restart: Bool
    var id: String { "\(entry.id)-\(pid)" }
}

/// Confirms ending a process PeachyPet did not start, naming it exactly.
struct ExternalStopSheet: View {
    let request: ExternalStopRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: t(request.restart ? "services.external.restart_title" : "services.external.stop_title"), request.entry.name))
                .font(Constants.heading(size: 18, weight: .heavy))
                .foregroundColor(Constants.textPrimary)
            Text(t("services.external.intro"))
                .font(Constants.body(size: 13))
                .foregroundColor(Constants.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "PID \(request.pid)")
                .font(Constants.body(size: 12, weight: .semibold))
                .foregroundColor(Constants.textPrimary)
            Text(SecretRedactor.redact(request.command))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Constants.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Constants.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button(t("permission.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                Button(t(request.restart ? "services.restart" : "services.stop"), action: onConfirm)
                    .buttonStyle(BrandGhostButton(color: Constants.destructiveRed))
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Constants.lightBackground)
    }
}

private struct ServiceDialogs: ViewModifier {
    let store: ServiceStore
    @Binding var pendingApproval: ServiceEntry?
    @Binding var pendingExternalStop: ExternalStopRequest?
    @Binding var pendingDelete: ServiceRegistryItem?
    @Binding var deleteBlocked: Bool

    func body(content: Content) -> some View {
        content
            .alert(t("services.delete.blocked"), isPresented: $deleteBlocked) {
                Button(t("services.delete.ok"), role: .cancel) {}
            }
            .alert(t("services.delete.title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button(t("permission.cancel"), role: .cancel) { pendingDelete = nil }
                Button(t("services.delete.confirm"), role: .destructive) {
                    if let item = pendingDelete { store.delete(item) }
                    pendingDelete = nil
                }
            } message: {
                Text(String(format: t("services.delete.message"), pendingDelete?.fileURL.lastPathComponent ?? ""))
            }
            .sheet(item: $pendingExternalStop) { request in
                ExternalStopSheet(request: request) {
                    store.terminateExternal(pid: request.pid, expectedCommand: request.command,
                                            thenStart: request.restart ? request.entry : nil)
                    pendingExternalStop = nil
                } onCancel: { pendingExternalStop = nil }
            }
            .sheet(item: $pendingApproval) { entry in
                ServiceApprovalSheet(entry: entry, status: store.approvalStatus(of: entry)) {
                    store.approveAndStart(entry)
                    pendingApproval = nil
                } onCancel: {
                    pendingApproval = nil
                }
            }
    }
}

/// A brew service or LaunchAgent row: status plus start / stop / restart for
/// operable ones; read-only groups show status only.
struct SystemServiceRow: View {
    let service: SystemService
    var error: String? = nil
    var onAction: (SystemServiceAction) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(Constants.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(Constants.heading(size: 14, weight: .bold))
                    .foregroundColor(Constants.textPrimary)
                Text(service.program ?? service.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Constants.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error {
                    Text(error).font(Constants.body(size: 11)).foregroundColor(Constants.destructiveRed).lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                statusBadge
                if service.isOperable {
                    if service.isRunning {
                        Button(t("services.restart")) { onAction(.restart) }
                            .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                        Button(t("services.stop")) { onAction(.stop) }
                            .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                    } else {
                        Button(t("services.start")) { onAction(.start) }
                            .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    }
                }
            }
            .fixedSize()
        }
        .padding(12)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
    }

    private var icon: String {
        switch service.group {
        case .brew: "mug"
        case .userAgent: "gearshape.2"
        case .appAgent: "app.badge"
        case .daemon: "lock.shield"
        }
    }

    private var statusBadge: some View {
        let green = Color(.sRGB, red: 22/255, green: 140/255, blue: 70/255)
        let (text, color) = service.isRunning ? (t("services.running"), green) : (t("services.stopped"), Constants.textMuted)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Constants.body(size: 11, weight: .medium)).foregroundColor(color).lineLimit(1)
        }
    }
}
