import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) var appStore
    @Environment(OverlayManager.self) var overlayManager
    /// `-initialSection <name>` on the command line opens a given page (used for
    /// screenshot checks); launch arguments are never persisted.
    @State private var selectedSection: SidebarSection =
        UserDefaults.standard.string(forKey: "initialSection").flatMap(SidebarSection.init(rawValue:)) ?? .inbox

    enum SidebarSection: String, CaseIterable {
        case inbox, sessions, agents, pets, settings

        var titleKey: String { "nav.\(rawValue)" }
        var eyebrow: String { rawValue.uppercased() }

        var icon: String {
            switch self {
            case .inbox: "tray"
            case .sessions: "terminal"
            case .agents: "point.3.connected.trianglepath.dotted"
            case .pets: "wand.and.stars"
            case .settings: "gear"
            }
        }
    }

    var body: some View {
        if !appStore.hasCompletedOnboarding {
            OnboardingView {
                appStore.hasCompletedOnboarding = true
                // Start services that were deferred during onboarding
                appStore.hotkeyManager.start()
                Task { await appStore.notificationService.requestPermission() }
            }
        } else {
            dashboardView
        }
    }

    private var dashboardView: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let nsImage = PeachyIconProvider.brandImage() {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    }
                    Text("PeachyPet")
                        .font(Constants.heading(size: 17, weight: .heavy))
                        .tracking(-0.4)
                        .foregroundColor(Constants.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ForEach(SidebarSection.allCases, id: \.self) { section in
                    SidebarNavItem(
                        section: section,
                        isSelected: selectedSection == section,
                        badge: badgeCount(for: section)
                    ) {
                        selectedSection = section
                    }
                }

                Spacer()

                SidebarMascotCard(
                    config: overlayManager.currentConfig,
                    activeCount: appStore.sessionStore.sessions.filter { $0.status == .active }.count
                ) {
                    selectedSection = .pets
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 8)
            .background(Constants.sidebarBackground)
            .navigationTitle("")
            .toolbar(.hidden, for: .automatic)
            .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            VStack(spacing: 0) {
                PaperBand(eyebrow: selectedSection.eyebrow, title: t(selectedSection.titleKey))
                detail(for: selectedSection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Constants.lightBackground)
        }
        .background(Constants.lightBackground)
        .onChange(of: appStore.navigateToMascotId) { _, newId in
            if newId != nil {
                selectedSection = .pets
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConnectionDoctor)) { _ in
            selectedSection = .agents
        }
    }

    @ViewBuilder
    private func detail(for section: SidebarSection) -> some View {
        switch section {
        case .inbox: InboxView()
        case .sessions: SessionListView()
        case .agents: AgentsView()
        case .pets: PeachyDashboardView()
        case .settings: SettingsView()
        }
    }

    private func badgeCount(for section: SidebarSection) -> Int {
        switch section {
        case .inbox: appStore.notificationStore.unreadCount + appStore.pendingPermissionStore.pending.count
        default: 0
        }
    }
}

// MARK: - Paper band

/// Paper-cut sky across the top of the detail column, with the page title and
/// a quick skin switcher.
private struct PaperBand: View {
    let eyebrow: String
    let title: String

    var body: some View {
        let skin = SkinStore.shared.current
        ZStack(alignment: .bottomLeading) {
            SkyBand(skin: skin)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(eyebrow)
                        .font(Constants.body(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(Constants.textMuted)
                    Text(title)
                        .font(Constants.heading(size: 22, weight: .heavy))
                        .tracking(-0.6)
                        .foregroundColor(Constants.textPrimary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            SkinQuickSwitcher()
                .padding(.top, 10)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(height: 72)
        .overlay(alignment: .bottom) { Rectangle().fill(Constants.line).frame(height: 1) }
    }
}

/// Title-bar style skin menu: current skin's dot and name.
private struct SkinQuickSwitcher: View {
    var body: some View {
        let store = SkinStore.shared
        Menu {
            ForEach(Skin.builtIn) { skin in
                Button(t(skin.nameKey)) { store.select(skin) }
            }
            if let accent = store.customAccent {
                Button(t("skin.custom")) { store.selectCustom(accent: accent) }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Constants.orangePrimary).frame(width: 9, height: 9)
                Text(t(store.current.nameKey))
                    .font(Constants.body(size: 12, weight: .medium))
                    .foregroundColor(Constants.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Constants.surfaceWhite))
            .overlay(Capsule().stroke(Constants.line, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(t("settings.skin"))
    }
}

// MARK: - Sidebar mascot

private struct SidebarMascotCard: View {
    let config: PeachyAnimationConfig?
    let activeCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MascotPosterView(config: config)
                    .frame(width: 92, height: 92)
                Text(config?.name ?? "PeachyPet")
                    .font(Constants.heading(size: 14, weight: .bold))
                    .foregroundColor(Constants.textPrimary)
                    .lineLimit(1)
                Text(String(format: t("sidebar.watching"), activeCount))
                    .font(Constants.body(size: 11))
                    .foregroundColor(Constants.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar Nav Item

private struct SidebarNavItem: View {
    let section: ContentView.SidebarSection
    let isSelected: Bool
    let badge: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)

                Text(t(section.titleKey))
                    .font(Constants.body(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if badge > 0 {
                    Text("\(badge)")
                        .font(Constants.body(size: 11, weight: .semibold))
                        .foregroundColor(Constants.accentText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Constants.chip, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundColor(isSelected ? Constants.accentText : (isHovered ? Constants.textPrimary : Constants.textMuted))
            .background(
                RoundedRectangle(cornerRadius: Constants.cornerRadius)
                    .fill(isSelected ? Constants.orangePrimaryLight : (isHovered ? Constants.chip : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
