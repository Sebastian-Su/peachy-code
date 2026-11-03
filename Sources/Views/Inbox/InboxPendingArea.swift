import SwiftUI

/// Top of the inbox: permission requests, questions and sessions waiting for a
/// reply. Answers go through the same store as the overlay card, so a request
/// answered in one place disappears from both.
struct InboxPendingArea: View {
    @Environment(AppStore.self) var appStore
    @Environment(OverlayManager.self) var overlayManager

    var body: some View {
        let permissions = appStore.pendingPermissionStore.pending
        let waiting = appStore.sessionStore.sessions.filter { $0.status == .active && $0.phase == .waitingInput }
        let items = InboxPending.build(
            permissions: permissions.map { ($0.id, $0.receivedAt) },
            waitingSessions: waiting.map { ($0.id, $0.lastEventAt ?? .distantPast) }
        )

        Group {
            if items.isEmpty {
                emptyStage
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: t("inbox.pending_count"), items.count))
                        .font(Constants.body(size: 11, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(Constants.textMuted)
                    ForEach(items) { item in
                        switch item {
                        case .permission(let id):
                            if let permission = permissions.first(where: { $0.id == id }) {
                                PendingPermissionCard(permission: permission)
                            }
                        case .waitingInput(let sessionId):
                            if let session = waiting.first(where: { $0.id == sessionId }) {
                                WaitingSessionCard(session: session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var emptyStage: some View {
        HStack(spacing: 14) {
            MascotPosterView(config: overlayManager.currentConfig)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(t("inbox.nothing_waiting"))
                    .font(Constants.heading(size: 17, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundColor(.white)
                Text(t("inbox.watching_note"))
                    .font(Constants.body(size: 13).italic())
                    .foregroundColor(Color(.sRGB, red: 1, green: 0.62, blue: 0.78))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Constants.stagePanel, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct PendingPermissionCard: View {
    @Environment(AppStore.self) var appStore
    let permission: PendingPermission

    private var summary: String? {
        let input = permission.event.toolInput
        return input?["command"]?.value as? String
            ?? input?["cmd"]?.value as? String
            ?? input?["file_path"]?.value as? String
            ?? input?["description"]?.value as? String
    }

    /// Questions and terminal-only requests need the full overlay card.
    private var answersInOverlay: Bool {
        permission.isTerminalFallback || permission.toolName == "AskUserQuestion"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.toolName == "AskUserQuestion" ? "questionmark.bubble.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 16))
                .foregroundColor(Constants.orangePrimary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.toolName)
                        .font(Constants.heading(size: 14, weight: .bold))
                        .foregroundColor(Constants.textPrimary)
                    if let project = permission.event.projectName {
                        Text(project).font(Constants.body(size: 11)).foregroundColor(Constants.textMuted)
                    }
                    Text("· " + permission.event.assistantDisplayName)
                        .font(Constants.body(size: 11)).foregroundColor(Constants.textMuted)
                    Spacer()
                    Text(relativeTimeString(from: permission.receivedAt))
                        .font(Constants.body(size: 11)).foregroundColor(Constants.textMuted)
                }
                if let summary {
                    Text(summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Constants.textPrimary)
                        .lineLimit(2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Constants.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 8) {
                    Spacer()
                    if answersInOverlay {
                        Button(t("inbox.answer_in_overlay")) {
                            appStore.pendingPermissionStore.expand(id: permission.id)
                        }
                        .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    } else {
                        Button(t("permission.deny")) {
                            appStore.pendingPermissionStore.resolve(id: permission.id, decision: .deny)
                        }
                        .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                        Button(t("permission.allow")) {
                            appStore.pendingPermissionStore.resolve(id: permission.id, decision: .allow)
                        }
                        .buttonStyle(BrandGhostButton(color: Constants.accentText))
                    }
                }
            }
        }
        .padding(12)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.orangePrimary.opacity(0.35), lineWidth: 1))
    }
}

private struct WaitingSessionCard: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 15))
                .foregroundColor(Constants.accentSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName ?? session.id)
                    .font(Constants.heading(size: 14, weight: .bold))
                    .foregroundColor(Constants.textPrimary)
                Text(t("inbox.waiting_input"))
                    .font(Constants.body(size: 12))
                    .foregroundColor(Constants.textMuted)
            }
            Spacer()
            Button(t("inbox.jump")) { IDETerminalFocus.focusSession(session) }
                .buttonStyle(BrandGhostButton(color: Constants.accentText))
        }
        .padding(12)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
    }
}
