import SwiftUI

struct SessionResultPluginSettings: View {
    @Bindable var plugin: SessionResultPlugin

    var body: some View {
        Section {
            Toggle(t("result_hook.enable"), isOn: $plugin.isEnabled)
            if plugin.isEnabled {
                Picker(t("result_hook.tool"), selection: $plugin.backend) {
                    Text("Codex CLI").tag(SessionResultTool.Backend.codex)
                    Text(t("result_hook.executable")).tag(SessionResultTool.Backend.executable)
                }
                TextField(t("result_hook.path"), text: $plugin.executablePath,
                          prompt: Text(plugin.backend == .codex ? t("result_hook.path_detect") : "/path/to/tool"))
                    .font(.system(.body, design: .monospaced))
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("result_hook.prompt"))
                    TextEditor(text: $plugin.instructions)
                        .frame(minHeight: 64, idealHeight: 84)
                        .accessibilityLabel(t("result_hook.prompt"))
                }
                Picker(t("result_hook.conversation"), selection: $plugin.conversation) {
                    Text(t("result_hook.new")).tag(SessionResultPlugin.Conversation.new)
                    Text(t("result_hook.reuse")).tag(SessionResultPlugin.Conversation.reuse)
                }
                Picker(t("result_hook.destination"), selection: $plugin.destination) {
                    Text(t("result_hook.panel")).tag(SessionResultPlugin.Destination.panel)
                    Text(t("result_hook.agent")).tag(SessionResultPlugin.Destination.agent)
                }
                if let error = plugin.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(t("result_hook.title")).font(Constants.heading(size: 13, weight: .semibold))
        }
    }
}
