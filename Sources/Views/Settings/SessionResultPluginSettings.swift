import SwiftUI

struct SessionResultHookEditor: View {
    let agent: AgentSource
    let plugin: SessionResultPlugin
    let saved: SessionResultPlugin.Configuration?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SessionResultPlugin.Configuration

    init(agent: AgentSource, plugin: SessionResultPlugin) {
        self.agent = agent
        self.plugin = plugin
        let saved = plugin.configuration(for: agent)
        self.saved = saved
        _draft = State(initialValue: saved ?? .init())
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(String(format: t("result_hook.editor_title"), agent.displayName))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Form {
                Toggle(t("result_hook.enable"), isOn: $draft.isEnabled)
                TextField(t("result_hook.trigger"), text: $draft.triggerKeyword,
                          prompt: Text(t("result_hook.trigger_default")))
                Picker(t("result_hook.tool"), selection: $draft.backend) {
                    Text("Codex CLI").tag(SessionResultTool.Backend.codex)
                    Text(t("result_hook.executable")).tag(SessionResultTool.Backend.executable)
                }
                TextField(t("result_hook.path"), text: $draft.executablePath,
                          prompt: Text(draft.backend == .codex ? t("result_hook.path_detect") : "/path/to/tool"))
                    .font(.system(.body, design: .monospaced))
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("result_hook.prompt"))
                    TextEditor(text: $draft.instructions)
                        .frame(minHeight: 94)
                        .accessibilityLabel(t("result_hook.prompt"))
                }
                Picker(t("result_hook.conversation"), selection: $draft.conversation) {
                    Text(t("result_hook.new")).tag(SessionResultPlugin.Conversation.new)
                    Text(t("result_hook.reuse")).tag(SessionResultPlugin.Conversation.reuse)
                }
                Picker(t("result_hook.destination"), selection: $draft.destination) {
                    Text(t("result_hook.panel")).tag(SessionResultPlugin.Destination.panel)
                    Text(t("result_hook.agent")).tag(SessionResultPlugin.Destination.agent)
                }
                if let error = plugin.lastErrors[agent] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button(t("permission.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("result_hook.save_limit")) {
                    plugin.save(draft, for: agent)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == saved)
            }
            .padding()
        }
        .frame(width: 550, height: 520)
    }
}

struct SessionResultHistorySettings: View {
    let results: SessionResultStore
    @State private var limitText = ""

    var body: some View {
        Section {
            HStack {
                Text(t("result_hook.history_limit"))
                Spacer()
                TextField(t("result_hook.history_limit"), text: $limitText)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Button(t("result_hook.save_limit"), action: saveLimit)
                    .disabled(Int(limitText).map { !SessionResultStore.historyRange.contains($0) || $0 == results.historyLimit } ?? true)
            }
        } header: {
            Text(t("nav.results")).font(Constants.heading(size: 13, weight: .semibold))
        }
        .onAppear { limitText = String(results.historyLimit) }
        .onChange(of: results.historyLimit) { _, limit in limitText = String(limit) }
    }

    private func saveLimit() {
        guard let limit = Int(limitText), SessionResultStore.historyRange.contains(limit),
              limit != results.historyLimit else { return }
        Task { await results.setHistoryLimit(limit) }
    }
}
