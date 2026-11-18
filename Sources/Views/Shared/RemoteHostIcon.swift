import SwiftUI

/// Marks a session that runs on another host, so its name needs no extra words.
struct RemoteHostIcon: View {
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "network")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Constants.textMuted)
            .help(t("sessions.remote_host"))
            .accessibilityLabel(t("sessions.remote_host"))
    }
}
