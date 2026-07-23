import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) var appStore
    @Environment(AppUpdater.self) var appUpdater
    @Environment(OverlayManager.self) var overlayManager
    @State private var isHookEnabled = false
    @State private var isCodexHookEnabled = false
    @State private var hookError: String?
    @State private var showUninstallConfirm = false
    @State private var portText: String = ""
    @State private var portError: String?
    @State private var videoCacheSize: Int64 = 0
    @State private var ideStatuses: [ExtensionInstaller.IDEStatus] = []
    @State private var extensionError: String?
    @State private var installingIDE: String?
    @State private var autoHideDelayText: String = "15"
    @State private var toastDurationText: String = "8"
    @State private var showConnectionDoctor = false
    @State private var selectedLanguage: AppLanguage = LanguageManager.shared.language

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        Form {
            // MARK: – Appearance
            Section {
                HStack {
                    Text(t("settings.language"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    Picker("", selection: $selectedLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selectedLanguage) { _, lang in
                        LanguageManager.shared.setLanguage(lang)
                    }
                }
            } header: {
                Text(t("settings.appearance")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – Overlay
            Section {
                // Auto-hide: toggle + delay in one row
                HStack {
                    Text(t("settings.auto_hide"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    if overlayManager.isAutoHideEnabled {
                        TextField("", text: $autoHideDelayText)
                            .frame(width: 52)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit {
                                if let value = Int(autoHideDelayText), value >= 1 {
                                    overlayManager.setAutoHideDelay(TimeInterval(value))
                                }
                                autoHideDelayText = String(Int(overlayManager.autoHideDelay))
                            }
                        Text(t("settings.seconds_unit"))
                            .font(.system(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                    Toggle("", isOn: Binding(
                        get: { overlayManager.isAutoHideEnabled },
                        set: { overlayManager.setAutoHideEnabled($0) }
                    ))
                    .labelsHidden()
                }

                // Toast: toggle + duration in one row
                HStack {
                    Text(t("settings.toast_enabled"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    if appStore.sessionFinishedStore.isEnabled {
                        TextField("", text: $toastDurationText)
                            .frame(width: 52)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit {
                                if let value = Double(toastDurationText), value >= 1 {
                                    appStore.sessionFinishedStore.toastDuration = value
                                }
                                toastDurationText = String(Int(appStore.sessionFinishedStore.toastDuration))
                            }
                        Text(t("settings.seconds_unit"))
                            .font(.system(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                    Toggle("", isOn: Binding(
                        get: { appStore.sessionFinishedStore.isEnabled },
                        set: { appStore.sessionFinishedStore.isEnabled = $0 }
                    ))
                    .labelsHidden()
                }
            } header: {
                Text(t("settings.overlay")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – Tools Integration (Claude Code + Codex + IDE Extensions unified)
            Section {
                // Claude Code hook row
                HStack {
                    Text("Claude Code")
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isHookEnabled },
                        set: { setClaudeHookEnabled($0) }
                    ))
                    .labelsHidden()
                }
                if let error = hookError {
                    Text(error).font(.system(size: 11)).foregroundColor(.red)
                }

                // Codex hook row
                HStack {
                    Text("Codex")
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isCodexHookEnabled },
                        set: { setCodexHookEnabled($0) }
                    ))
                    .labelsHidden()
                }
                if isHookEnabled && isCodexHookEnabled {
                    Text(t("settings.codex_hook_hint"))
                        .font(.system(size: 11))
                        .foregroundColor(Constants.textMuted)
                }

                // IDE extensions
                ForEach(ideStatuses) { ide in
                    HStack {
                        Text(ide.name)
                            .foregroundColor(ide.isDetected ? Constants.textPrimary : Constants.textMuted.opacity(0.5))
                        Spacer()
                        if installingIDE == ide.command {
                            ProgressView().controlSize(.small)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { ide.isInstalled },
                                set: { setIDEExtension(ide, enabled: $0) }
                            ))
                            .labelsHidden()
                            .disabled(!ide.isDetected)
                        }
                    }
                    .font(.system(size: 13))
                }

                if let error = extensionError {
                    Text(error).font(.system(size: 11)).foregroundColor(.red)
                }
            } header: {
                Text(t("settings.tools_integration")).font(Constants.heading(size: 13, weight: .semibold))
            }
            .animation(.easeInOut(duration: 0.25), value: installingIDE)

            // MARK: – Keyboard Shortcuts
            Section {
                HStack {
                    Text(t("settings.global_shortcuts"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appStore.hotkeyManager.isActive ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 8, height: 8)
                        Text(appStore.hotkeyManager.isActive ? "Active" : "Needs Accessibility")
                            .foregroundColor(Constants.textMuted)
                    }
                }
                HStack {
                    Text(t("settings.focus_toggle"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    ShortcutRecorderView(hotkeyManager: appStore.hotkeyManager)
                }
                VStack(alignment: .leading, spacing: 4) {
                    shortcutRow("⌘1-9", "Accept Nth pending permission")
                    shortcutRow("Hold ⌘", "Show numbered badges on permissions")
                }
                .padding(.vertical, 2)
                if !appStore.hotkeyManager.isActive {
                    Button(t("settings.grant_accessibility")) {
                        appStore.hotkeyManager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Constants.orangePrimary)
                }
            } header: {
                Text(t("settings.keyboard_shortcuts")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – Connection
            Section {
                HStack {
                    Text(t("settings.local_server"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appStore.localServer.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(appStore.localServer.isRunning ? "Port \(appStore.localServer.port)" : "Offline")
                            .foregroundColor(Constants.textMuted)
                    }
                }
                HStack {
                    Text(t("settings.port"))
                        .foregroundColor(Constants.textPrimary)
                    Spacer()
                    TextField("Port", text: $portText)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { applyPort() }
                    Button(t("settings.apply")) { applyPort() }
                        .buttonStyle(.plain)
                        .foregroundColor(Constants.orangePrimary)
                        .font(.system(size: 12, weight: .medium))
                }
                if let error = portError {
                    Text(error).font(.system(size: 11)).foregroundColor(.red)
                }
                if !appStore.localServer.isRunning {
                    Button(t("settings.restart_server")) {
                        appStore.localServer.restart(port: appStore.localServer.port)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Constants.orangePrimary)
                }
            } header: {
                Text(t("settings.connection")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – Storage
            Section {
                HStack {
                    Text(t("settings.sessions")).foregroundColor(Constants.textPrimary)
                    Spacer()
                    Text("\(appStore.sessionStore.sessions.count)").foregroundColor(Constants.textMuted)
                }
                HStack {
                    Text(t("settings.notifications")).foregroundColor(Constants.textPrimary)
                    Spacer()
                    Text("\(appStore.notificationStore.notifications.count)").foregroundColor(Constants.textMuted)
                }
                HStack {
                    Text(t("settings.video_cache")).foregroundColor(Constants.textPrimary)
                    Spacer()
                    Text(formatBytes(videoCacheSize)).foregroundColor(Constants.textMuted)
                }
                Button(action: clearVideoCache) {
                    Text(t("settings.clear_video_cache")).foregroundColor(Constants.orangePrimary)
                }
                .buttonStyle(.plain)
                .disabled(videoCacheSize == 0)

                HStack {
                    Text(t("settings.data_location")).foregroundColor(Constants.textPrimary)
                    Spacer()
                    Text(LocalStorage.appSupportDir.path)
                        .font(.system(size: 10))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text(t("settings.storage")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – Updates
            Section {
                if appUpdater.isAvailable {
                    @Bindable var updater = appUpdater
                    Toggle(t("settings.auto_check_updates"), isOn: $updater.automaticallyChecksForUpdates)
                        .foregroundColor(Constants.textPrimary)
                    Button(action: { appUpdater.checkForUpdates() }) {
                        Text(t("settings.check_updates")).foregroundColor(Constants.orangePrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appUpdater.canCheckForUpdates)
                } else {
                    Text(t("settings.updates_unavailable"))
                        .font(.system(size: 12)).foregroundColor(Constants.textMuted)
                }
            } header: {
                Text(t("settings.updates")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – Troubleshooting
            Section {
                Button {
                    showConnectionDoctor = true
                } label: {
                    HStack {
                        Image(systemName: "stethoscope").foregroundColor(Constants.orangePrimary)
                        Text(t("settings.run_doctor")).foregroundColor(Constants.orangePrimary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(Constants.textMuted)
                    }
                }
                .buttonStyle(.plain)
                Text(t("settings.doctor_hint")).font(.system(size: 11)).foregroundColor(Constants.textMuted)
            } header: {
                Text(t("settings.troubleshooting")).font(Constants.heading(size: 13, weight: .semibold))
            }

            // MARK: – About
            Section {
                HStack {
                    Text(t("settings.version")).foregroundColor(Constants.textPrimary)
                    Spacer()
                    Text("\(appVersion) (\(buildNumber))").foregroundColor(Constants.textMuted)
                }
                Link(destination: URL(string: Constants.repoURL)!) {
                    HStack {
                        Text(t("settings.github")).foregroundColor(Constants.orangePrimary)
                        Spacer()
                        Image(systemName: "arrow.up.forward").foregroundColor(Constants.orangePrimary).font(.caption)
                    }
                }
                Link(destination: URL(string: Constants.peachyBaseURL + "/community")!) {
                    HStack {
                        Image(systemName: "sparkles").foregroundColor(Constants.orangePrimary).font(.system(size: 12))
                        Text(t("settings.browse_skins")).foregroundColor(Constants.orangePrimary)
                        Spacer()
                        Image(systemName: "arrow.up.forward").foregroundColor(Constants.orangePrimary).font(.caption)
                    }
                }
                Button(action: { showUninstallConfirm = true }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(t("settings.uninstall_peachy"))
                    }
                    .foregroundColor(Color(.sRGB, red: 220/255, green: 38/255, blue: 38/255))
                }
                .buttonStyle(.plain)
                Text(t("settings.uninstall_hint")).font(.system(size: 11)).foregroundColor(Constants.textMuted)
            } header: {
                Text(t("settings.about")).font(Constants.heading(size: 13, weight: .semibold))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Constants.lightBackground)
        .navigationTitle("Settings")
        .task {
            // Fast, synchronous — safe on main thread
            isHookEnabled = HookInstaller.isRegistered()
            isCodexHookEnabled = CodexHookInstaller.isRegistered()
            videoCacheSize = VideoCache.shared.cacheSize
            autoHideDelayText = String(Int(overlayManager.autoHideDelay))
            toastDurationText = String(Int(appStore.sessionFinishedStore.toastDuration))
            selectedLanguage = LanguageManager.shared.language
            portText = String(appStore.localServer.port)

            // Show cached IDE statuses immediately (no flash on repeat visits)
            if !appStore.cachedIDEStatuses.isEmpty {
                ideStatuses = appStore.cachedIDEStatuses
            }

            // Refresh in background — updates cache for next visit
            let statuses = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: ExtensionInstaller.allIDEStatuses())
                }
            }
            guard !Task.isCancelled else { return }
            ideStatuses = statuses
            appStore.cachedIDEStatuses = statuses
        }
        .sheet(isPresented: $showConnectionDoctor) {
            ConnectionDoctorView()
                .environment(appStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConnectionDoctor)) { _ in
            showConnectionDoctor = true
        }
        .alert("Uninstall Peachy?", isPresented: $showUninstallConfirm) {
            Button(t("permission.cancel"), role: .cancel) {}
            Button(t("settings.uninstall_peachy"), role: .destructive) { performUninstall() }
        } message: {
            Text(t("settings.uninstall_confirm"))
        }
    }

    private func applyPort() {
        portError = nil
        guard let value = UInt16(portText), value >= 1024 else {
            portError = "Enter a port between 1024 and 65535"
            return
        }
        if value == appStore.localServer.port && appStore.localServer.isRunning {
            return // No change needed
        }
        appStore.localServer.restart(port: value)
        portText = String(value)
    }

    private func setClaudeHookEnabled(_ enabled: Bool) {
        hookError = nil
        do {
            if enabled {
                try HookInstaller.install()
            } else {
                try HookInstaller.uninstall()
            }
            PeachyEventBus.setInstallEnabled(enabled, for: .claudeCode)
        } catch {
            hookError = error.localizedDescription
        }
        isHookEnabled = HookInstaller.isRegistered()
    }

    private func setCodexHookEnabled(_ enabled: Bool) {
        hookError = nil
        do {
            if enabled {
                try CodexHookInstaller.install()
            } else {
                try CodexHookInstaller.uninstall()
            }
            PeachyEventBus.setInstallEnabled(enabled, for: .codex)
        } catch {
            hookError = error.localizedDescription
        }
        isCodexHookEnabled = CodexHookInstaller.isRegistered()
    }

    private func clearVideoCache() {
        VideoCache.shared.clearCache()
        videoCacheSize = 0
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 MB" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb < 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f MB", mb)
    }

    private func refreshIDEStatuses() {
        ideStatuses = ExtensionInstaller.allIDEStatuses()
    }

    private func setIDEExtension(_ ide: ExtensionInstaller.IDEStatus, enabled: Bool) {
        extensionError = nil
        installingIDE = ide.command
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if enabled {
                    try ExtensionInstaller.install(command: ide.command)
                    UserDefaults.standard.set(ExtensionInstaller.bundledVersion, forKey: "ideExtensionVersion")
                } else {
                    try ExtensionInstaller.uninstall(command: ide.command)
                }
                let statuses = ExtensionInstaller.allIDEStatuses()
                DispatchQueue.main.async {
                    ideStatuses = statuses
                    appStore.cachedIDEStatuses = statuses
                    installingIDE = nil
                    if enabled {
                        ExtensionInstaller.triggerPermissionPrompt()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    extensionError = error.localizedDescription
                    installingIDE = nil
                    refreshIDEStatuses()
                }
            }
        }
    }

    private func performUninstall() {
        let fm = FileManager.default

        // 1. Remove hooks from ~/.claude/settings.json
        try? HookInstaller.uninstall()

        // 1.5. Remove IDE extension
        ExtensionInstaller.uninstall()

        // 2. Delete hook script dir (current + legacy names)
        for dir in ["/.peachypet", "/.peachy-code", "/.masko-desktop"] {
            try? fm.removeItem(atPath: NSHomeDirectory() + dir)
        }

        // 3. Delete ~/Library/Application Support/PeachyPet/
        try? fm.removeItem(at: LocalStorage.appSupportDir)

        // 4. Delete ~/Library/Caches/PeachyPet/
        let cacheDir = VideoCache.shared.cacheDir.deletingLastPathComponent()
        try? fm.removeItem(at: cacheDir)

        // 5. Clear UserDefaults — all known bundle IDs (current + legacy)
        for domain in ["com.peachy.pet", "com.peachy.code", "com.masko.desktop", "masko-code"] {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        UserDefaults.standard.synchronize()

        // 5.5. Delete preference plist files explicitly (current + legacy)
        for plist in ["com.peachy.pet.plist", "com.peachy.code.plist", "com.masko.desktop.plist", "masko-code.plist", "PeachyPet.plist"] {
            let path = NSHomeDirectory() + "/Library/Preferences/" + plist
            try? fm.removeItem(atPath: path)
        }

        // 6. Quit the app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        HStack(spacing: 8) {
            Text(shortcut)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Constants.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Constants.textMuted.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(Constants.textMuted)
        }
    }
}

// MARK: - Shortcut Recorder

/// A clickable view that records a keyboard shortcut when focused.
struct ShortcutRecorderView: View {
    var hotkeyManager: GlobalHotkeyManager
    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    Text(t("settings.press_shortcut"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Constants.orangePrimary)
                } else {
                    Text(hotkeyManager.shortcutLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Constants.textPrimary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isRecording ? Constants.orangePrimary.opacity(0.08) : Constants.textMuted.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Constants.orangePrimary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        hotkeyManager.shared.isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            var flags: CGEventFlags = []
            if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
            if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
            if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
            if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }

            // Require at least one modifier
            guard !flags.isEmpty else { return event }

            // Escape cancels recording
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            // Use hardware keyCode directly — works on all keyboard layouts
            hotkeyManager.setShortcut(keyCode: Int64(event.keyCode), modifiers: flags)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        hotkeyManager.shared.isRecording = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
