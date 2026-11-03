import SwiftUI

/// One block per engine: whether its hooks are really installed, how many
/// sessions it ran and which apps hosted them. Install status is read-only here;
/// toggling integrations stays in Settings.
struct AgentsView: View {
    @Environment(AppStore.self) var appStore
    @State private var installed: [AgentSource: Bool] = [:]
    @State private var showDoctor = false

    var body: some View {
        let overview = AgentOverview.build(sessions: appStore.sessionStore.sessions, installed: installed)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(overview) { AgentBlock(agent: $0) }
                Button {
                    showDoctor = true
                } label: {
                    Label(t("agents.run_doctor"), systemImage: "stethoscope")
                }
                .buttonStyle(BrandGhostButton(color: Constants.accentText))
            }
            .padding(20)
        }
        .background(Constants.lightBackground)
        .onAppear { installed = AgentOverview.readInstallStatus() }
        .sheet(isPresented: $showDoctor, onDismiss: { installed = AgentOverview.readInstallStatus() }) {
            ConnectionDoctorView()
                .environment(appStore)
                .frame(minWidth: 520, minHeight: 560)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConnectionDoctor)) { _ in showDoctor = true }
    }
}

private struct AgentBlock: View {
    let agent: AgentOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = iconBundleId.flatMap(AppIconProvider.icon(forBundleId:)) {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                } else {
                    Image(systemName: agent.engine.sfSymbol)
                        .font(.system(size: 20))
                        .foregroundColor(Constants.textMuted)
                        .frame(width: 28, height: 28)
                }
                Text(agent.engine.displayName)
                    .font(Constants.heading(size: 18, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundColor(Constants.textPrimary)
                installBadge
                Spacer()
                Text(String(format: t("agents.session_counts"), agent.sessionCount, agent.activeCount))
                    .font(Constants.body(size: 12))
                    .foregroundColor(Constants.textMuted)
            }

            if agent.hosts.isEmpty {
                Text(t("agents.no_sessions"))
                    .font(Constants.body(size: 12))
                    .foregroundColor(Constants.textMuted)
            } else {
                HostDistribution(hosts: agent.hosts, total: agent.sessionCount)
            }
        }
        .padding(16)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadius).stroke(Constants.line, lineWidth: 1))
    }

    private var iconBundleId: String? {
        switch agent.engine {
        case .claudeCode: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        default: nil
        }
    }

    private var installBadge: some View {
        let color = agent.isInstalled ? Color(.sRGB, red: 22/255, green: 140/255, blue: 70/255) : Constants.textMuted
        return Text(agent.isInstalled ? t("agents.installed") : t("agents.not_installed"))
            .font(Constants.body(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Dark stage panel with one bar per host kind.
private struct HostDistribution: View {
    let hosts: [AgentOverview.HostCount]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(hosts, id: \.kind) { host in
                HStack(spacing: 8) {
                    hostIcon(host.kind)
                        .frame(width: 18, height: 18)
                    Text(hostName(host.kind))
                        .font(Constants.body(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Constants.orangePrimary)
                            .frame(width: max(4, geo.size.width * CGFloat(host.count) / CGFloat(max(total, 1))))
                    }
                    .frame(height: 8)
                    Text("\(host.count)")
                        .font(Constants.body(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Constants.stagePanel, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
    }

    @ViewBuilder
    private func hostIcon(_ kind: AgentOverview.HostKind) -> some View {
        let bundleId: String? = switch kind {
        case .paseo: PaseoRegistry.bundleId
        case .codexDesktop: "com.openai.codex"
        case .terminal: "com.apple.Terminal"
        default: nil
        }
        if let icon = bundleId.flatMap(AppIconProvider.icon(forBundleId:)) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: kind == .other ? "app.dashed" : "questionmark.circle")
                .resizable()
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func hostName(_ kind: AgentOverview.HostKind) -> String {
        switch kind {
        case .paseo: "Paseo"
        case .codexDesktop: t("sessions.host.codex_desktop")
        case .terminal: t("sessions.host.terminal")
        case .other: t("agents.host.other")
        case .unknown: t("sessions.host.unknown")
        }
    }
}
