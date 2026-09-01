import AppKit
import SwiftUI

private enum QWorkPendingGenerationAction {
    case create
    case resume(projectID: UUID)
    case regenerateState(projectID: UUID, stateID: String)
    case regenerateTransition(projectID: UUID, transitionID: String)
}

struct MascotCreationCenterView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(OverlayManager.self) private var overlayManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProjectID: UUID?
    @State private var name = t("creator.default_name")
    @State private var stylePreset = MascotStylePreset.soft3D
    @State private var stylePrompt = MascotStylePreset.soft3D.prompt
    @State private var selectedStates: Set<MascotStateTemplate> = [.idle, .working, .thinking]
    @State private var statePrompts = Dictionary(
        uniqueKeysWithValues: MascotStateTemplate.allCases.map { ($0, $0.prompt) }
    )
    @State private var providerID = MockMediaGenerationProvider.providerID
    @State private var referenceURL: URL?
    @State private var styleReferenceURL: URL?
    @State private var removeFlatBackground = true
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var qworkQuoteSummary: QWorkGenerationQuoteSummary?
    @State private var showingQWorkQuote = false
    @State private var qworkPendingAction: QWorkPendingGenerationAction?

    private var projectStore: MascotProjectStore { appStore.mascotProjectStore }
    private var providerSettings: MediaProviderSettingsStore { appStore.mediaProviderSettings }
    private var coordinator: MascotCreationCoordinator {
        MascotCreationCoordinator(
            projectStore: projectStore,
            providerSettings: providerSettings,
            mascotStore: appStore.mascotStore
        )
    }
    private var selectedProject: MascotProject? {
        guard let selectedProjectID else { return nil }
        return projectStore.project(id: selectedProjectID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("creator.title"))
                        .font(Constants.heading(size: 20, weight: .bold))
                    Text(t("creator.subtitle"))
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                }
                Spacer()
                Button(t("creator.open_data_folder")) {
                    NSWorkspace.shared.open(projectStore.rootURL)
                }
                .buttonStyle(BrandGhostButton())
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Constants.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            HSplitView {
                projectSidebar
                    .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
                ScrollView {
                    if let project = selectedProject {
                        projectDetail(project)
                    } else {
                        newProjectForm
                    }
                }
                .frame(minWidth: 540)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Constants.lightBackground)
        .alert(t("creator.qwork_quote_title"), isPresented: $showingQWorkQuote) {
            Button(t("permission.cancel"), role: .cancel) { cancelQWorkGeneration() }
            Button(t("creator.qwork_quote_continue")) { confirmQWorkGeneration() }
        } message: {
            Text(qworkQuoteMessage)
        }
    }

    private var projectSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selectedProjectID = nil
                message = nil
            } label: {
                Label(t("creator.new_masko"), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(BrandSecondaryButton())

            Button {
                importPackage()
            } label: {
                Label(t("creator.import_package"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(BrandGhostButton())

            Divider()

            Text(t("creator.local_projects"))
                .font(Constants.heading(size: 12, weight: .semibold))
                .foregroundColor(Constants.textMuted)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(projectStore.projects) { project in
                        Button {
                            selectedProjectID = project.id
                            message = nil
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(statusColor(project.status))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .lineLimit(1)
                                        .foregroundColor(Constants.textPrimary)
                                    Text(statusName(project.status))
                                        .font(Constants.body(size: 10))
                                        .foregroundColor(Constants.textMuted)
                                }
                                Spacer()
                            }
                            .padding(9)
                            .background(
                                selectedProjectID == project.id
                                    ? Constants.orangePrimaryLight
                                    : Constants.surfaceWhite
                            )
                            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Constants.surfaceWhite)
    }

    private var newProjectForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("1", t("creator.character_style"))

            TextField(t("creator.masko_name"), text: $name)
                .textFieldStyle(.roundedBorder)

            Picker(t("creator.built_in_style"), selection: $stylePreset) {
                ForEach(MascotStylePreset.allCases) { preset in
                    Text(styleName(preset)).tag(preset)
                }
            }
            .onChange(of: stylePreset) { _, preset in
                if preset != .custom { stylePrompt = preset.prompt }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("creator.style_prompt"))
                    .font(Constants.heading(size: 12, weight: .semibold))
                TextEditor(text: $stylePrompt)
                    .font(Constants.body(size: 12))
                    .frame(height: 70)
                    .padding(6)
                    .background(Constants.surfaceWhite)
                    .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                            .stroke(Constants.border, lineWidth: 1)
                    )
            }

            HStack(spacing: 12) {
                Button {
                    chooseReference()
                } label: {
                    Label(
                        t(referenceURL == nil ? "creator.choose_character" : "creator.change_character"),
                        systemImage: "photo"
                    )
                }
                .buttonStyle(BrandSecondaryButton())

                if let referenceURL {
                    Text(referenceURL.lastPathComponent)
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(1)
                }
            }

            Toggle(t("creator.remove_background"), isOn: $removeFlatBackground)
                .toggleStyle(.checkbox)
                .font(Constants.body(size: 11))

            HStack(spacing: 12) {
                Button {
                    chooseStyleReference()
                } label: {
                    Label(
                        t(styleReferenceURL == nil ? "creator.optional_style_image" : "creator.change_style_image"),
                        systemImage: "photo.stack"
                    )
                }
                .buttonStyle(BrandGhostButton())

                if let styleReferenceURL {
                    Text(styleReferenceURL.lastPathComponent)
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                        .lineLimit(1)
                }
            }

            sectionTitle("2", t("creator.states"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                ForEach(MascotStateTemplate.allCases) { state in
                    Toggle(isOn: stateBinding(state)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stateName(state))
                                .font(Constants.heading(size: 13, weight: .semibold))
                            Text(state.prompt)
                                .font(Constants.body(size: 10))
                                .foregroundColor(Constants.textMuted)
                                .lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(state == .idle)
                    .padding(10)
                    .background(Constants.surfaceWhite)
                    .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(t("creator.motion_prompts"))
                    .font(Constants.heading(size: 12, weight: .semibold))
                ForEach(MascotStateTemplate.allCases.filter { selectedStates.contains($0) }) { state in
                    HStack {
                        Text(stateName(state))
                            .font(Constants.body(size: 11, weight: .medium))
                            .frame(width: 110, alignment: .leading)
                        TextField(t("creator.motion_prompt"), text: statePromptBinding(state))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(12)
            .background(Constants.surfaceWhite)
            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))

            sectionTitle("3", t("creator.generation_provider"))
            Picker(t("creator.provider"), selection: $providerID) {
                Text(t("creator.provider_mock")).tag(MockMediaGenerationProvider.providerID)
                Text(t("creator.provider_custom")).tag(MediaProviderSettingsStore.customHTTPProviderID)
                Text(t("creator.provider_qwork")).tag(QWorkSidecarMediaGenerationProvider.providerID)
            }
            .pickerStyle(.segmented)
            .onChange(of: providerID) { _, _ in apiKey = "" }

            if providerID == MediaProviderSettingsStore.customHTTPProviderID {
                customProviderForm
            } else if providerID == QWorkSidecarMediaGenerationProvider.providerID {
                qworkProviderForm
            }

            if let message {
                statusMessage(message)
            }

            HStack {
                Spacer()
                Button {
                    beginCreateAndGenerate()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(t("creator.create_generate"), systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(BrandPrimaryButton(isDisabled: !canCreate || isWorking))
                .disabled(!canCreate || isWorking)
            }
        }
        .padding(22)
    }

    private var customProviderForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(t("creator.base_url"), text: Bindable(providerSettings).baseURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField(t("creator.image_path"), text: Bindable(providerSettings).imagePath)
                TextField(t("creator.video_path"), text: Bindable(providerSettings).videoPath)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                TextField(t("creator.image_model"), text: Bindable(providerSettings).imageModel)
                TextField(t("creator.video_model"), text: Bindable(providerSettings).videoModel)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                TextField(t("creator.api_key_header"), text: Bindable(providerSettings).apiKeyHeader)
                SecureField(
                    t(providerSettings.hasAPIKey ? "creator.api_key_saved" : "creator.api_key"),
                    text: $apiKey
                )
            }
            .textFieldStyle(.roundedBorder)
            Text(t("creator.bridge_contract"))
                .font(Constants.body(size: 10))
                .foregroundColor(Constants.textMuted)
        }
        .padding(12)
        .background(Constants.surfaceWhite)
        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
    }

    private var qworkProviderForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(t("creator.base_url"), text: Bindable(providerSettings).qworkBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField(t("creator.video_model"), text: Bindable(providerSettings).qworkVideoModel)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField(t("creator.api_key_header"), text: Bindable(providerSettings).qworkAPIKeyHeader)
                SecureField(
                    t(providerSettings.hasStoredAPIKey(for: providerID) ? "creator.api_key_saved" : "creator.api_key"),
                    text: $apiKey
                )
            }
            .textFieldStyle(.roundedBorder)
            Text(t("creator.qwork_contract"))
                .font(Constants.body(size: 10))
                .foregroundColor(Constants.textMuted)
            Text(t("creator.qwork_auth_hint"))
                .font(Constants.body(size: 10))
                .foregroundColor(Constants.textMuted)
        }
        .padding(12)
        .background(Constants.surfaceWhite)
        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
    }

    private func projectDetail(_ project: MascotProject) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(Constants.heading(size: 20, weight: .bold))
                    Text(String(
                        format: t("creator.project_summary"),
                        project.states.count,
                        project.transitions.count
                    ))
                        .font(Constants.body(size: 12))
                        .foregroundColor(Constants.textMuted)
                }
                Spacer()
                Text(statusName(project.status))
                    .font(Constants.heading(size: 11, weight: .semibold))
                    .foregroundColor(statusColor(project.status))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(statusColor(project.status).opacity(0.12), in: Capsule())
            }

            if !project.blocks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(t("creator.blocked_items"), systemImage: "exclamationmark.triangle.fill")
                        .font(Constants.heading(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                    ForEach(project.blocks) { block in
                        Text("• \(block.message)")
                            .font(Constants.body(size: 11))
                            .foregroundColor(Constants.textMuted)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
            }

            Text(t("creator.states"))
                .font(Constants.heading(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 12) {
                ForEach(project.states) { state in
                    stateCard(state, project: project)
                }
            }

            Text(t("creator.transitions"))
                .font(Constants.heading(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 8) {
                ForEach(project.transitions) { transition in
                    VStack(alignment: .leading, spacing: 7) {
                        if let video = transition.video,
                           let url = try? projectStore.assetURL(video, projectID: project.id) {
                            MascotVideoView(url: url)
                                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 110)
                        }
                        HStack {
                            Text(stateName(id: transition.source))
                            Image(systemName: "arrow.right")
                            Text(stateName(id: transition.target))
                            Spacer()
                            Image(systemName: transition.video == nil ? "clock" : "checkmark.circle.fill")
                                .foregroundColor(transition.video == nil ? Constants.textMuted : .green)
                        }
                        if transition.video != nil {
                            Button(t("creator.regenerate")) {
                                beginRegenerateTransition(project: project, transitionID: transition.id)
                            }
                            .buttonStyle(BrandGhostButton())
                            .disabled(isWorking)
                        }
                    }
                    .font(Constants.body(size: 11))
                    .padding(10)
                    .background(Constants.surfaceWhite)
                    .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
                }
            }

            if let message {
                statusMessage(message)
            }

            HStack(spacing: 10) {
                Button(t("creator.export_package")) { exportPackage(project) }
                    .buttonStyle(BrandGhostButton())
                Button(t("creator.generate_resume")) { beginResume(project) }
                    .buttonStyle(BrandSecondaryButton())
                    .disabled(isWorking)
                Spacer()
                Button(t("creator.activate")) { activate(project) }
                    .buttonStyle(BrandPrimaryButton(isDisabled: project.status != .ready))
                    .disabled(project.status != .ready)
            }
        }
        .padding(22)
    }

    private func stateCard(_ state: MascotStateDraft, project: MascotProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                anchorPreview(state, project: project)
                if let loop = state.loop,
                   let url = try? projectStore.assetURL(loop, projectID: project.id) {
                    MascotVideoView(url: url)
                        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 120)
                }
            }
            HStack {
                Text(stateName(id: state.id, fallback: state.name))
                    .font(Constants.heading(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: state.loop == nil ? "clock" : "checkmark.circle.fill")
                    .foregroundColor(state.loop == nil ? Constants.textMuted : .green)
            }
            if let score = state.validation?.seamScore {
                Text(String(format: t("creator.seam_score"), Int(score * 100)))
                    .font(Constants.body(size: 10))
                    .foregroundColor(score >= MediaValidator.defaultSimilarityThreshold ? .green : .orange)
            }
            if state.anchor != nil || state.loop != nil {
                Button(t("creator.regenerate_state")) {
                    beginRegenerateState(project: project, stateID: state.id)
                }
                .buttonStyle(BrandGhostButton())
                .disabled(isWorking)
            }
        }
        .padding(10)
        .background(Constants.surfaceWhite)
        .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
    }

    @ViewBuilder
    private func anchorPreview(_ state: MascotStateDraft, project: MascotProject) -> some View {
        if let anchor = state.anchor,
           let url = try? projectStore.assetURL(anchor, projectID: project.id),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 120)
        } else {
            RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall)
                .fill(Constants.stage)
                .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 120)
                .overlay(Image(systemName: "photo").foregroundColor(Constants.textMuted))
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && referenceURL != nil
            && selectedStates.contains(.idle)
    }

    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(Constants.heading(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Constants.orangePrimary, in: Circle())
            Text(title)
                .font(Constants.heading(size: 15, weight: .semibold))
        }
    }

    private func statusMessage(_ text: String) -> some View {
        Text(text)
            .font(Constants.body(size: 11))
            .foregroundColor(Constants.textMuted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Constants.surfaceWhite)
            .clipShape(RoundedRectangle(cornerRadius: Constants.cornerRadiusSmall))
    }

    private func stateBinding(_ state: MascotStateTemplate) -> Binding<Bool> {
        Binding(
            get: { selectedStates.contains(state) },
            set: { selected in
                if selected { selectedStates.insert(state) } else { selectedStates.remove(state) }
            }
        )
    }

    private func statePromptBinding(_ state: MascotStateTemplate) -> Binding<String> {
        Binding(
            get: { statePrompts[state] ?? state.prompt },
            set: { statePrompts[state] = $0 }
        )
    }

    private func statusColor(_ status: MascotProjectStatus) -> Color {
        switch status {
        case .ready: .green
        case .generating: Constants.orangePrimary
        case .blocked, .needsReview: .orange
        case .failed: .red
        case .draft: Constants.textMuted
        }
    }

    private func statusName(_ status: MascotProjectStatus) -> String {
        t("creator.status.\(status.rawValue)")
    }

    private func stateName(_ state: MascotStateTemplate) -> String {
        t("creator.state.\(state.rawValue)")
    }

    private func stateName(id: String, fallback: String? = nil) -> String {
        guard let state = MascotStateTemplate(rawValue: id) else { return fallback ?? id }
        return stateName(state)
    }

    private func styleName(_ style: MascotStylePreset) -> String {
        t("creator.style.\(style.rawValue)")
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = t("creator.choose_character_panel")
        if panel.runModal() == .OK {
            referenceURL = panel.url
        }
    }

    private func chooseStyleReference() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = t("creator.choose_style_panel")
        if panel.runModal() == .OK {
            styleReferenceURL = panel.url
        }
    }

    private var qworkQuoteMessage: String {
        guard let summary = qworkQuoteSummary else { return "" }
        return String(
            format: t("creator.qwork_quote_message"),
            summary.videoTaskCount,
            summary.maximumUnitCredits,
            summary.maximumTotalCredits
        )
    }

    private func beginCreateAndGenerate() {
        guard providerID == QWorkSidecarMediaGenerationProvider.providerID else {
            createAndGenerate()
            return
        }
        requestQWorkConfirmation(
            videoTaskCount: selectedStates.count + 2 * max(0, selectedStates.count - 1),
            action: .create,
            saveCurrentConfiguration: true
        )
    }

    private func beginResume(_ project: MascotProject) {
        let videoTaskCount = project.states.filter { $0.loop == nil }.count +
            project.transitions.filter { $0.video == nil }.count
        guard project.providerID == QWorkSidecarMediaGenerationProvider.providerID,
              videoTaskCount > 0 else {
            generate(projectID: project.id)
            return
        }
        requestQWorkConfirmation(
            videoTaskCount: videoTaskCount,
            action: .resume(projectID: project.id)
        )
    }

    private func beginRegenerateState(project: MascotProject, stateID: String) {
        guard project.providerID == QWorkSidecarMediaGenerationProvider.providerID else {
            regenerateState(projectID: project.id, stateID: stateID)
            return
        }
        let videoTaskCount = 1 + project.transitions.filter {
            $0.source == stateID || $0.target == stateID
        }.count
        requestQWorkConfirmation(
            videoTaskCount: videoTaskCount,
            action: .regenerateState(projectID: project.id, stateID: stateID)
        )
    }

    private func beginRegenerateTransition(project: MascotProject, transitionID: String) {
        guard project.providerID == QWorkSidecarMediaGenerationProvider.providerID else {
            regenerateTransition(projectID: project.id, transitionID: transitionID)
            return
        }
        requestQWorkConfirmation(
            videoTaskCount: 1,
            action: .regenerateTransition(projectID: project.id, transitionID: transitionID)
        )
    }

    private func requestQWorkConfirmation(
        videoTaskCount: Int,
        action: QWorkPendingGenerationAction,
        saveCurrentConfiguration: Bool = false
    ) {
        isWorking = true
        message = t("creator.qwork_quote_loading")
        Task { @MainActor in
            defer { isWorking = false }
            do {
                if saveCurrentConfiguration {
                    try providerSettings.saveConfiguration(
                        apiKey: apiKey.isEmpty ? nil : apiKey,
                        providerID: QWorkSidecarMediaGenerationProvider.providerID
                    )
                }
                let quote = try await providerSettings.quoteQWorkImageToVideo()
                qworkQuoteSummary = QWorkGenerationQuoteSummary(
                    quote: quote,
                    videoTaskCount: videoTaskCount
                )
                qworkPendingAction = action
                message = nil
                showingQWorkQuote = true
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func cancelQWorkGeneration() {
        qworkQuoteSummary = nil
        qworkPendingAction = nil
        providerSettings.clearQWorkCostApproval()
    }

    private func confirmQWorkGeneration() {
        guard let summary = qworkQuoteSummary, let action = qworkPendingAction else { return }
        providerSettings.approveQWorkQuote(summary.quote)
        qworkQuoteSummary = nil
        qworkPendingAction = nil
        switch action {
        case .create:
            createAndGenerate()
        case .resume(let projectID):
            generate(projectID: projectID)
        case .regenerateState(let projectID, let stateID):
            regenerateState(projectID: projectID, stateID: stateID)
        case .regenerateTransition(let projectID, let transitionID):
            regenerateTransition(projectID: projectID, transitionID: transitionID)
        }
    }

    private func createAndGenerate() {
        guard let referenceURL else { return }
        do {
            let project = try coordinator.createProject(MascotProjectCreationRequest(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                stylePrompt: stylePrompt,
                states: selectedStates,
                statePrompts: statePrompts,
                providerID: providerID,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                referenceURL: referenceURL,
                styleReferenceURL: styleReferenceURL,
                removeFlatBackground: removeFlatBackground
            ))
            apiKey = ""
            selectedProjectID = project.id
            generate(projectID: project.id)
        } catch {
            if providerID == QWorkSidecarMediaGenerationProvider.providerID {
                providerSettings.clearQWorkCostApproval()
            }
            message = error.localizedDescription
        }
    }

    private func generate(projectID: UUID) {
        let usesQWork = projectStore.project(id: projectID)?.providerID ==
            QWorkSidecarMediaGenerationProvider.providerID
        isWorking = true
        message = t("creator.generating")
        Task { @MainActor in
            defer {
                isWorking = false
                if usesQWork { providerSettings.clearQWorkCostApproval() }
            }
            do {
                let completed = try await coordinator.generate(projectID: projectID)
                if completed.status == .ready {
                    message = t("creator.ready_message")
                } else {
                    message = t("creator.blocked_message")
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func activate(_ project: MascotProject) {
        do {
            let config = try coordinator.compileAndSave(project)
            if !overlayManager.isOverlayEnabled { overlayManager.enableOverlay() }
            overlayManager.showOverlayWithConfig(config)
            message = String(format: t("creator.activated_message"), project.name)
        } catch {
            message = error.localizedDescription
        }
    }

    private func regenerateState(projectID: UUID, stateID: String) {
        do {
            try coordinator.resetState(projectID: projectID, stateID: stateID)
            generate(projectID: projectID)
        } catch {
            if projectStore.project(id: projectID)?.providerID ==
                QWorkSidecarMediaGenerationProvider.providerID {
                providerSettings.clearQWorkCostApproval()
            }
            message = error.localizedDescription
        }
    }

    private func regenerateTransition(projectID: UUID, transitionID: String) {
        do {
            try coordinator.resetTransition(projectID: projectID, transitionID: transitionID)
            generate(projectID: projectID)
        } catch {
            if projectStore.project(id: projectID)?.providerID ==
                QWorkSidecarMediaGenerationProvider.providerID {
                providerSettings.clearQWorkCostApproval()
            }
            message = error.localizedDescription
        }
    }

    private func exportPackage(_ project: MascotProject) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name + ".masko"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try coordinator.export(project, to: url)
                message = String(format: t("creator.exported_message"), url.lastPathComponent)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = t("creator.choose_package_panel")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let project = try coordinator.importPackage(at: url)
                selectedProjectID = project.id
                message = String(format: t("creator.imported_message"), project.name)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
