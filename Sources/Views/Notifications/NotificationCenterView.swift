import SwiftUI

struct NotificationCenterView: View {
    @Environment(AppStore.self) var appStore
    @Environment(ViewClock.self) var clock
    @State private var showClearAllConfirmation = false

    var body: some View {
        let _ = clock.tick
        let isEmpty = appStore.notificationStore.notifications.isEmpty
        let hasUnread = appStore.notificationStore.unreadCount > 0

        VStack(spacing: 0) {
            HStack {
                Text(t("notifications.title"))
                    .font(Constants.heading(size: 22, weight: .semibold))
                    .foregroundColor(Constants.textPrimary)
                Spacer()
                Button(t("notifications.mark_read")) {
                    appStore.notificationStore.markAllAsRead()
                }
                .buttonStyle(.plain)
                .font(Constants.body(size: 13, weight: .medium))
                .foregroundColor(hasUnread ? Constants.orangePrimary : Constants.textMuted)
                .disabled(!hasUnread)

                Button(t("notifications.clear")) {
                    showClearAllConfirmation = true
                }
                .buttonStyle(.plain)
                .font(Constants.body(size: 13, weight: .medium))
                .foregroundColor(isEmpty ? Constants.textMuted : Constants.destructiveRed)
                .disabled(isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(Constants.border)

            if isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "bell")
                        .font(.system(size: 36))
                        .foregroundColor(Constants.textMuted)
                    Text(t("notifications.empty"))
                        .font(Constants.heading(size: 22, weight: .semibold))
                        .foregroundColor(Constants.textPrimary)
                    Text(t("notifications.hint"))
                        .font(Constants.body(size: 14))
                        .foregroundColor(Constants.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Constants.lightBackground)
            } else {
                List(appStore.notificationStore.notifications) { notification in
                    NotificationRow(notification: notification)
                        .onTapGesture {
                            appStore.notificationStore.markAsRead(notification.id)
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Constants.lightBackground)
            }
        }
        .background(Constants.lightBackground)
        .overlay {
            if showClearAllConfirmation {
                ClearAllConfirmationDialog(
                    onConfirm: {
                        appStore.notificationStore.clearAll()
                        showClearAllConfirmation = false
                    },
                    onCancel: {
                        showClearAllConfirmation = false
                    }
                )
            }
        }
    }
}

// MARK: - Clear All Confirmation Dialog

private struct ClearAllConfirmationDialog: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 16) {
                Image(systemName: "trash")
                    .font(.system(size: 28))
                    .foregroundColor(Constants.destructiveRed)

                Text(t("notifications.clear_all"))
                    .font(Constants.heading(size: 16, weight: .semibold))
                    .foregroundColor(Constants.textPrimary)

                Text(t("notifications.clear_confirm"))
                    .font(Constants.body(size: 13))
                    .foregroundColor(Constants.textMuted)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(t("notifications.cancel")) { onCancel() }
                        .buttonStyle(.plain)
                        .font(Constants.body(size: 13, weight: .medium))
                        .foregroundColor(Constants.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Constants.cornerRadius)
                                .stroke(Constants.border, lineWidth: 1)
                        )

                    Button(t("notifications.clear")) { onConfirm() }
                        .buttonStyle(.plain)
                        .font(Constants.body(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: Constants.cornerRadius)
                                .fill(Constants.destructiveRed)
                        )
                }
            }
            .padding(24)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Constants.surfaceWhite)
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            )
        }
    }
}

struct NotificationRow: View {
    let notification: AppNotification
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(notification.isRead ? Color.clear : Constants.orangePrimary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(notification.isRead
                        ? Constants.body(size: compact ? 11 : 14)
                        : Constants.heading(size: compact ? 11 : 14, weight: .semibold))
                    .foregroundColor(Constants.textPrimary)

                if let body = notification.body {
                    Text(body)
                        .font(Constants.body(size: compact ? 10 : 13))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(compact ? 1 : 2)
                }

                if !compact {
                    HStack {
                        Text(notification.category.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(Constants.body(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 180/255, green: 90/255, blue: 0))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Constants.chip, in: Capsule())

                        Spacer()

                        Text(relativeTimeString(from: notification.createdAt))
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                }
            }
        }
        .padding(.vertical, compact ? 2 : 4)
        .opacity(notification.isRead ? 0.7 : 1)
    }
}
