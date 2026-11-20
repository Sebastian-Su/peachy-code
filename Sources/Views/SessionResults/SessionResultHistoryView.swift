import AppKit
import SwiftUI

struct SessionResultHistoryView: View {
    let store: SessionResultStore
    let sessionStore: SessionStore

    @State private var selectedID: UUID?
    @State private var report: SessionResultReport?

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    t(store.historyUnavailable ? "result_hook.history_unavailable" : "result_hook.history_empty"),
                    systemImage: "doc.text"
                )
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(store.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: entry.agent.sfSymbol)
                                    .foregroundStyle(entry.agent.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.sessionTitle ?? entry.label)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    Text(entry.label)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(entry.receivedAt, format: .dateTime.month().day().hour().minute())
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 3)
                            .tag(entry.id)
                        }
                    }
                    .frame(minWidth: 190, idealWidth: 245, maxWidth: 360)

                    Group {
                        if let report, report.source.id == selectedID {
                            reportDetail(report)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: store.navigation) {
            await store.refresh()
            guard !Task.isCancelled else { return }
            let requested = store.navigation?.reportID
            selectedID = store.entries.first(where: { $0.id == requested })?.id ?? store.entries.first?.id
        }
        .onChange(of: store.entries.map(\.id)) { _, ids in
            if selectedID.map({ !ids.contains($0) }) ?? true {
                selectedID = ids.first
            }
        }
        .task(id: selectedID) {
            let result: SessionResultReport?
            if let selectedID {
                result = await store.report(id: selectedID)
            } else {
                result = nil
            }
            if !Task.isCancelled { report = result }
        }
    }

    private func reportDetail(_ report: SessionResultReport) -> some View {
        let source = report.source
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.sessionTitle ?? source.label)
                        .font(.headline)
                    Text(source.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(source.sessionID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let session = sessionStore.sessions.first(where: { $0.id == source.sessionID && $0.agentSource == source.agent }) {
                    Button {
                        IDETerminalFocus.focusSession(session)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help(t("result_hook.open_source"))
                    .accessibilityLabel(t("result_hook.open_source"))
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.markdown, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(t("result_hook.copy"))
                .accessibilityLabel(t("result_hook.copy"))
            }
            .padding()
            Divider()
            ReportTextView(markdown: report.markdown)
                .id(source.id)
        }
    }
}
