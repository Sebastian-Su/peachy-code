import Foundation

struct MascotProjectCreationRequest {
    let name: String
    let stylePrompt: String
    let states: Set<MascotStateTemplate>
    let statePrompts: [MascotStateTemplate: String]
    let providerID: String
    let apiKey: String?
    let referenceURL: URL
    let styleReferenceURL: URL?
    let removeFlatBackground: Bool
}

@MainActor
struct MascotCreationCoordinator {
    let projectStore: MascotProjectStore
    let providerSettings: MediaProviderSettingsStore
    let mascotStore: MascotStore

    func createProject(_ request: MascotProjectCreationRequest) throws -> MascotProject {
        if request.providerID == MediaProviderSettingsStore.customHTTPProviderID ||
            request.providerID == QWorkSidecarMediaGenerationProvider.providerID {
            try providerSettings.saveConfiguration(apiKey: request.apiKey, providerID: request.providerID)
        }
        var project = try projectStore.createProject(
            name: request.name,
            stylePrompt: request.stylePrompt,
            states: MascotStateTemplate.allCases.filter { request.states.contains($0) },
            providerID: request.providerID
        )
        project.removeFlatBackground = request.removeFlatBackground
        for index in project.states.indices {
            if let template = MascotStateTemplate(rawValue: project.states[index].id) {
                project.states[index].prompt = request.statePrompts[template] ?? template.prompt
            }
        }
        project.reference = try projectStore.importAsset(
            from: request.referenceURL,
            relativePath: "character/reference.\(fileExtension(request.referenceURL))",
            mediaType: .image,
            projectID: project.id
        )
        if let styleReferenceURL = request.styleReferenceURL {
            project.styleReference = try projectStore.importAsset(
                from: styleReferenceURL,
                relativePath: "styles/reference.\(fileExtension(styleReferenceURL))",
                mediaType: .image,
                projectID: project.id
            )
        }
        try projectStore.save(project)
        return project
    }

    func generate(projectID: UUID) async throws -> MascotProject {
        guard let project = projectStore.project(id: projectID) else {
            throw MascotGenerationPipelineError.projectNotFound
        }
        let provider = try providerSettings.makeProvider(id: project.providerID)
        let completed = try await MascotGenerationPipeline(
            store: projectStore,
            provider: provider
        ).generate(projectID: projectID)
        if completed.status == .ready {
            _ = try compileAndSave(completed)
        }
        return completed
    }

    func compileAndSave(_ project: MascotProject) throws -> PeachyAnimationConfig {
        let config = try AnimationCompiler().compile(
            project: project,
            projectDirectory: projectStore.projectDirectory(for: project.id)
        )
        mascotStore.addOrUpdateFromProject(config: config, projectID: project.id)
        return config
    }

    func resetState(projectID: UUID, stateID: String) throws {
        guard var project = projectStore.project(id: projectID),
              let stateIndex = project.states.firstIndex(where: { $0.id == stateID }) else { return }
        project.states[stateIndex].anchor = nil
        project.states[stateIndex].loop = nil
        project.states[stateIndex].validation = nil
        for index in project.transitions.indices
        where project.transitions[index].source == stateID || project.transitions[index].target == stateID {
            project.transitions[index].video = nil
            project.transitions[index].validation = nil
        }
        try projectStore.save(project)
    }

    func resetTransition(projectID: UUID, transitionID: String) throws {
        guard var project = projectStore.project(id: projectID),
              let index = project.transitions.firstIndex(where: { $0.id == transitionID }) else { return }
        project.transitions[index].video = nil
        project.transitions[index].validation = nil
        try projectStore.save(project)
    }

    func export(_ project: MascotProject, to url: URL) throws {
        try MascotPackageService().export(
            project: project,
            from: projectStore.projectDirectory(for: project.id),
            to: url
        )
    }

    func importPackage(at url: URL) throws -> MascotProject {
        try MascotPackageService().importPackage(at: url, into: projectStore)
    }

    private func fileExtension(_ url: URL) -> String {
        url.pathExtension.isEmpty ? "png" : url.pathExtension
    }
}
