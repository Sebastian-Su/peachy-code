import Foundation

enum MascotGenerationPipelineError: LocalizedError {
    case projectNotFound
    case missingReference

    var errorDescription: String? {
        switch self {
        case .projectNotFound: t("creator.error.project_not_found")
        case .missingReference: t("creator.error.missing_reference")
        }
    }
}

final class MascotGenerationPipeline {
    private let store: MascotProjectStore
    private let provider: any MediaGenerationProvider
    private let validator: any MascotMediaValidating

    init(
        store: MascotProjectStore,
        provider: any MediaGenerationProvider,
        validator: any MascotMediaValidating = MediaValidator()
    ) {
        self.store = store
        self.provider = provider
        self.validator = validator
    }

    func generate(projectID: UUID) async throws -> MascotProject {
        guard var project = store.project(id: projectID) else {
            throw MascotGenerationPipelineError.projectNotFound
        }
        guard let reference = project.reference else {
            project.status = .blocked
            project.blocks = [MascotCreationBlock(id: "missing-reference", message: t("creator.error.missing_reference_short"))]
            try store.save(project)
            throw MascotGenerationPipelineError.missingReference
        }

        project.status = .generating
        project.blocks = []
        try store.save(project)
        let referenceURL = try store.assetURL(reference, projectID: project.id)
        let styleURL = try project.styleReference.map { try store.assetURL($0, projectID: project.id) }

        for index in project.states.indices {
            do {
                if project.states[index].anchor == nil {
                    let state = project.states[index]
                    updateJob(kind: .anchor, targetID: state.id, status: .running, project: &project)
                    try store.save(project)
                    let media = try await provider.generateAnchor(
                        request: AnchorGenerationRequest(
                            project: project,
                            state: state,
                            referenceURL: referenceURL,
                            styleReferenceURL: styleURL
                        )
                    )
                    let anchorData = project.removeFlatBackground ?? true
                        ? try ImageBackgroundRemover.removeFlatBackground(from: media.data)
                        : media.data
                    let relative = "states/\(state.id)/anchor.\(safeExtension(media.fileExtension))"
                    project.states[index].anchor = try store.writeAsset(
                        anchorData,
                        relativePath: relative,
                        mediaType: .image,
                        projectID: project.id
                    )
                    updateJob(kind: .anchor, targetID: state.id, status: .complete, project: &project)
                    try store.save(project)
                }

                guard let anchor = project.states[index].anchor else { continue }
                let anchorURL = try store.assetURL(anchor, projectID: project.id)
                _ = try validator.validateImage(at: anchorURL)

                if project.states[index].loop == nil {
                    let state = project.states[index]
                    updateJob(kind: .loop, targetID: state.id, status: .running, project: &project)
                    try store.save(project)
                    let media = try await provider.generateLoop(
                        request: LoopGenerationRequest(project: project, state: state, anchorURL: anchorURL)
                    )
                    let relative = "states/\(state.id)/loop.\(safeExtension(media.fileExtension))"
                    project.states[index].loop = try store.writeAsset(
                        media.data,
                        relativePath: relative,
                        mediaType: .video,
                        projectID: project.id
                    )
                    updateJob(kind: .loop, targetID: state.id, status: .complete, project: &project)
                    try store.save(project)
                }

                if let loop = project.states[index].loop {
                    let result = try await validator.validateLoop(
                        videoURL: store.assetURL(loop, projectID: project.id),
                        anchorURL: anchorURL
                    )
                    project.states[index].validation = result
                    if !result.passed {
                        addBlock(id: "loop-\(project.states[index].id)", message: result.messages.joined(separator: "; "), project: &project)
                    }
                }
            } catch {
                addBlock(id: "state-\(project.states[index].id)", message: error.localizedDescription, project: &project)
            }
            try store.save(project)
        }

        for index in project.transitions.indices {
            do {
                let transition = project.transitions[index]
                guard let source = project.states.first(where: { $0.id == transition.source })?.anchor,
                      let target = project.states.first(where: { $0.id == transition.target })?.anchor else {
                    addBlock(
                        id: "transition-\(transition.id)",
                        message: t("creator.error.incomplete_transition_anchors"),
                        project: &project
                    )
                    continue
                }
                let sourceURL = try store.assetURL(source, projectID: project.id)
                let targetURL = try store.assetURL(target, projectID: project.id)
                if transition.video == nil {
                    updateJob(kind: .transition, targetID: transition.id, status: .running, project: &project)
                    try store.save(project)
                    let media = try await provider.generateTransition(
                        request: TransitionGenerationRequest(
                            project: project,
                            transition: transition,
                            sourceAnchorURL: sourceURL,
                            targetAnchorURL: targetURL
                        )
                    )
                    let relative = "transitions/\(transition.id)/clip.\(safeExtension(media.fileExtension))"
                    project.transitions[index].video = try store.writeAsset(
                        media.data,
                        relativePath: relative,
                        mediaType: .video,
                        projectID: project.id
                    )
                    updateJob(kind: .transition, targetID: transition.id, status: .complete, project: &project)
                    try store.save(project)
                }
                if let video = project.transitions[index].video {
                    let result = try await validator.validateTransition(
                        videoURL: store.assetURL(video, projectID: project.id),
                        sourceAnchorURL: sourceURL,
                        targetAnchorURL: targetURL
                    )
                    project.transitions[index].validation = result
                    if !result.passed {
                        addBlock(id: "transition-\(transition.id)", message: result.messages.joined(separator: "; "), project: &project)
                    }
                }
            } catch {
                addBlock(id: "transition-\(project.transitions[index].id)", message: error.localizedDescription, project: &project)
            }
            try store.save(project)
        }

        project.status = project.blocks.isEmpty ? .ready : .blocked
        try store.save(project)
        return store.project(id: project.id) ?? project
    }

    private func updateJob(
        kind: MascotGenerationJobKind,
        targetID: String,
        status: MascotGenerationJobStatus,
        message: String? = nil,
        project: inout MascotProject
    ) {
        let id = "\(kind.rawValue):\(targetID)"
        if let index = project.jobs.firstIndex(where: { $0.id == id }) {
            project.jobs[index].status = status
            project.jobs[index].message = message
        } else {
            project.jobs.append(
                MascotGenerationJob(id: id, kind: kind, targetID: targetID, status: status, message: message)
            )
        }
    }

    private func addBlock(id: String, message: String, project: inout MascotProject) {
        guard !project.blocks.contains(where: { $0.id == id }) else { return }
        for index in project.jobs.indices where project.jobs[index].status == .running {
            project.jobs[index].status = .failed
            project.jobs[index].message = message
        }
        project.blocks.append(MascotCreationBlock(id: id, message: message))
        updateJob(kind: .validation, targetID: id, status: .blocked, message: message, project: &project)
    }

    private func safeExtension(_ value: String) -> String {
        let cleaned = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? "bin" : cleaned
    }
}
