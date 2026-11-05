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
                    ServiceRow(item: item)
                }
            }
            .padding(20)
        }
        .background(Constants.lightBackground)
        .onAppear { store.startWatching() }
        .onDisappear { store.stopWatching() }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(Constants.body(size: 11, weight: .semibold))
            .tracking(1)
            .foregroundColor(Constants.textMuted)
    }
}

struct ServiceRow: View {
    let item: ServiceRegistryItem

    var body: some View {
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
                case .invalid(let reason):
                    Text(t("services.format_error") + " · " + reason.message)
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.destructiveRed)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Constants.surfaceWhite, in: RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall).stroke(Constants.line, lineWidth: 1))
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
