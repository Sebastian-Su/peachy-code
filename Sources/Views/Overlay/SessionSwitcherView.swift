import SwiftUI

/// Compact session switcher overlay positioned near the mascot.
/// Triggered by double-tap Cmd when 2+ sessions are active.
struct SessionSwitcherView: View {
    @Environment(SessionSwitcherStore.self) var store
    @Environment(GlobalHotkeyManager.self) var hotkeyManager

    var body: some View {
        if store.isActive {
            VStack(alignment: .leading, spacing: 0) {
                if store.sessions.isEmpty {
                    Text(t("switcher.no_sessions"))
                        .font(Constants.body(size: 11))
                        .foregroundStyle(Constants.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionSwitcherRow(
                            session: session,
                            index: index,
                            isSelected: index == store.selectedIndex,
                            showShortcuts: hotkeyManager.isCmdHeld,
                            onTap: { store.tapConfirm(index: index) }
                        )

                        if index < store.sessions.count - 1 {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }

                // Hint bar — always visible
                Divider()
                Text("⌘⌘ switch · ⌘↵ focus · esc cancel")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 35/255, green: 17/255, blue: 60/255).opacity(0.35))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .animation(.easeInOut(duration: 0.15), value: hotkeyManager.isCmdHeld)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                    .stroke(Constants.border, lineWidth: 1)
            )
            .shadow(color: Constants.cardShadowColor, radius: 4, x: 0, y: 2)
        }
    }
}

private struct SessionSwitcherRow: View {
    let session: AgentSession
    let index: Int
    let isSelected: Bool
    let showShortcuts: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Orange left accent for selected row
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Constants.orangePrimary : Color.clear)
                .frame(width: 3, height: 28)

            // Phase status dot
            Circle()
                .fill(phaseColor)
                .frame(width: 7, height: 7)

            // Project name + phase
            VStack(alignment: .leading, spacing: 1) {
                Text(projectLabel)
                    .font(Constants.body(size: 11, weight: .medium))
                    .foregroundStyle(Constants.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(phaseLabel)
                    if let ago = relativeTime {
                        Text("·")
                        Text(ago)
                    }
                }
                .font(Constants.body(size: 9))
                .foregroundStyle(Constants.textMuted)

                if visibleSubagentCount > 0 {
                    HStack(spacing: 4) {
                        ForEach(0..<visibleSubagentCount, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1.25)
                                .fill(Constants.orangePrimary)
                                .frame(width: 10, height: 2.5)
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: visibleSubagentCount)

            Spacer()

            // Real app icon (terminal / desktop client) — represents where a click goes
            if let bundleId = session.focusAppBundleId,
               let icon = AppIconProvider.icon(forBundleId: bundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Constants.textMuted)
            }

            // Shortcut badge — only when Cmd is held
            if showShortcuts {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Constants.textMuted)
                    .padding(.trailing, 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(isSelected ? Constants.orangePrimarySubtle : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var visibleSubagentCount: Int {
        min(max(session.activeSubagentCount, 0), 5)
    }

    private var projectLabel: String {
        if let name = session.projectName { return name }
        if let dir = session.projectDir {
            return URL(fileURLWithPath: dir).lastPathComponent
        }
        return "Session"
    }

    private var phaseColor: Color {
        switch session.phase {
        case .running: return .green
        case .idle: return Color(red: 160/255, green: 160/255, blue: 170/255)
        case .compacting: return .purple
        }
    }

    private var phaseLabel: String {
        switch session.phase {
        case .running: return "Running"
        case .idle: return "Idle"
        case .compacting: return "Compacting"
        }
    }

    private var relativeTime: String? {
        guard let date = session.lastEventAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
