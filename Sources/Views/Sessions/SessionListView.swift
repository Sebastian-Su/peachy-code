import SwiftUI

/// Sessions: active on top, recently ended below; selecting one shows where it
/// came from and where the jump button goes.
struct SessionListView: View {
    @Environment(AppStore.self) var appStore
    @Environment(ViewClock.self) var clock
    @State private var selectedSession: AgentSession?

    var body: some View {
        let _ = clock.tick
        let sessions = appStore.sessionStore.sessions
        let active = sessions.filter { $0.status == .active }
        let ended = sessions.filter { $0.status != .active }
        HStack(spacing: 0) {
            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        sectionHeader(t("sessions.active"), count: active.count)
                        ForEach(active) { row($0) }
                        sectionHeader(t("sessions.ended"), count: ended.count)
                        ForEach(ended) { row($0) }
                    }
                    .padding(8)
                }
                .frame(minWidth: 320, idealWidth: 392, maxWidth: 440)
                Rectangle().fill(Constants.line).frame(width: 1)
                Group {
                    if let selected = selectedSession.flatMap({ s in sessions.first { $0.id == s.id } }) {
                        SessionInspector(session: selected)
                    } else {
                        Text(t("sessions.select_hint"))
                            .font(Constants.body(size: 13))
                            .foregroundColor(Constants.textMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Constants.surfaceWhite)
            }
        }
        .background(Constants.lightBackground)
        .onAppear { if selectedSession == nil { selectedSession = active.first ?? sessions.first } }
    }

    private func row(_ session: AgentSession) -> some View {
        SessionRow(session: session, isSelected: selectedSession?.id == session.id)
            .contentShape(Rectangle())
            .onTapGesture { selectedSession = session }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(Constants.body(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundColor(Constants.textMuted)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundColor(Constants.textMuted)
            Text(t("sessions.no_sessions"))
                .font(Constants.heading(size: 22, weight: .semibold))
                .foregroundColor(Constants.textPrimary)
            Text(t("sessions.hint"))
                .font(Constants.body(size: 14))
                .foregroundColor(Constants.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Inspector

private struct SessionInspector: View {
    let session: AgentSession

    var body: some View {
        let route = SessionRoute(session: session)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayProjectName)
                    .font(Constants.heading(size: 22, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundColor(Constants.textPrimary)
                if let title = session.displaySessionTitle {
                    Text(title)
                        .font(Constants.body(size: 13))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(3)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(t("sessions.route_title"))
                    .font(Constants.body(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(Constants.textMuted)
                HStack(spacing: 0) {
                    RouteNode(icon: engineIcon(route.engine), title: route.engine.displayName, caption: t("sessions.route_engine"))
                    RouteArrow()
                    RouteNode(icon: route.destinationBundleId.flatMap(AppIconProvider.icon(forBundleId:)),
                              title: destinationName(route.destination),
                              caption: t("sessions.route_host"))
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Constants.stagePanel, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
            }

            if route.canJump {
                Button {
                    IDETerminalFocus.focusSession(session)
                } label: {
                    Text(String(format: t("sessions.jump_to"), destinationName(route.destination)))
                }
                .buttonStyle(BrandPrimaryButton())
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button {} label: { Text(t("sessions.cannot_jump")) }
                        .buttonStyle(BrandPrimaryButton())
                        .disabled(true)
                        .opacity(0.45)
                    Text(t("sessions.cannot_jump_reason"))
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                infoRow(t("sessions.status"), statusText)
                infoRow(t("sessions.events_label"), "\(session.eventCount)")
                if let last = session.lastEventAt { infoRow(t("sessions.last_activity"), relativeTimeString(from: last)) }
                if let dir = session.projectDir { infoRow(t("sessions.directory"), dir) }
            }
            Spacer()
        }
        .padding(20)
    }

    private var statusText: String {
        if session.status != .active { return t("sessions.state.ended") }
        switch session.phase {
        case .running, .compacting: return t("sessions.state.running")
        case .waitingInput: return t("sessions.state.waiting")
        case .idle: return t("sessions.state.idle")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Constants.body(size: 12))
                .foregroundColor(Constants.textMuted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Constants.body(size: 12))
                .foregroundColor(Constants.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func engineIcon(_ engine: AgentSource) -> NSImage? {
        switch engine {
        case .claudeCode: AppIconProvider.icon(forBundleId: "com.anthropic.claudefordesktop")
        case .codex: AppIconProvider.icon(forBundleId: "com.openai.codex")
        default: nil
        }
    }

    private func destinationName(_ destination: SessionRoute.Destination) -> String {
        switch destination {
        case .terminal:
            session.focusAppBundleId
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? t("sessions.host.terminal")
        case .codexDesktop: t("sessions.host.codex_desktop")
        case .paseo: "Paseo"
        case .other(let originator): originator
        case .unknown: t("sessions.host.unknown")
        }
    }
}

private struct RouteNode: View {
    let icon: NSImage?
    let title: String
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else {
                    Image(systemName: "questionmark.app.dashed").resizable().foregroundColor(.white.opacity(0.6))
                }
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            Text(title)
                .font(Constants.heading(size: 13, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(caption)
                .font(Constants.body(size: 10))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RouteArrow: View {
    var body: some View {
        HStack(spacing: 2) {
            Rectangle().fill(Constants.orangePrimary).frame(width: 46, height: 2)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 9))
                .foregroundColor(Constants.orangePrimary)
        }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            Image(systemName: session.status == .active ? "circle.fill" : "circle")
                .foregroundColor(session.status == .active ? Color.green : Constants.textMuted)
                .font(.caption)

            AgentSourceBadge(source: session.agentSource, compact: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayProjectName)
                    .font(Constants.heading(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? Constants.orangePrimary : Constants.textPrimary)
                HStack {
                    Text("\(session.eventCount) \(t("sessions.events"))")
                        .font(Constants.body(size: 11))
                        .foregroundColor(Constants.textMuted)
                    if let lastEvent = session.lastEventAt {
                        Text("\(t("sessions.last")) \(relativeTimeString(from: lastEvent))")
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                }
            }

            Spacer()

            if let bundleId = session.focusAppBundleId, let icon = AppIconProvider.icon(forBundleId: bundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }

            Text(session.status.rawValue.capitalized)
                .font(Constants.body(size: 11, weight: .medium))
                .foregroundColor(session.status == .active ? Color.green : Constants.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    session.status == .active
                        ? Color.green.opacity(0.1)
                        : Constants.border,
                    in: Capsule()
                )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                .fill(isSelected ? Constants.orangePrimarySubtle : (isHovered ? Constants.chip.opacity(0.6) : Color.clear))
        )
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                    .strokeBorder(Constants.orangePrimary.opacity(0.3), lineWidth: 1)
                : nil
        )
        .onHover { isHovered = $0 }
    }
}

extension AgentSession: Hashable {
    static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
