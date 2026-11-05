import SwiftUI

/// First-run confirmation: shows exactly what will run before anything executes.
struct ServiceApprovalSheet: View {
    let entry: ServiceEntry
    let status: ServiceApproval.Status
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: t("services.approve.title"), entry.name))
                .font(Constants.heading(size: 18, weight: .heavy))
                .foregroundColor(Constants.textPrimary)
            Text(intro)
                .font(Constants.body(size: 13))
                .foregroundColor(Constants.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            field(t("services.approve.command"), entry.command, changed: changed.contains(.command))
            field(t("services.approve.cwd"), entry.cwd ?? t("services.approve.home"), changed: changed.contains(.cwd))
            if !entry.env.isEmpty || changed.contains(.env) {
                field(t("services.approve.env"),
                      entry.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"),
                      changed: changed.contains(.env))
            }
            if let modified = entry.modifiedAt {
                Text(String(format: t("services.approve.modified"),
                            modified.formatted(date: .abbreviated, time: .standard)))
                    .font(Constants.body(size: 11))
                    .foregroundColor(Constants.textMuted)
            }
            HStack {
                Spacer()
                Button(t("permission.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(BrandGhostButton(color: Constants.textMuted))
                Button(t("services.approve.confirm"), action: onConfirm)
                    .buttonStyle(BrandGhostButton(color: Constants.accentText))
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Constants.lightBackground)
    }

    private var changed: [ServiceApproval.Field] {
        if case .changed(let fields) = status { return fields }
        return []
    }

    private var intro: String {
        changed.isEmpty ? t("services.approve.intro_new") : t("services.approve.intro_changed")
    }

    private func field(_ label: String, _ value: String, changed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Constants.body(size: 11, weight: .semibold))
                    .foregroundColor(Constants.textMuted)
                if changed {
                    Text(t("services.approve.changed"))
                        .font(Constants.body(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Constants.destructiveRed, in: Capsule())
                }
            }
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Constants.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Constants.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(changed ? Constants.destructiveRed : Color.clear, lineWidth: 1))
        }
    }
}

extension ServiceEntry: Identifiable {}
