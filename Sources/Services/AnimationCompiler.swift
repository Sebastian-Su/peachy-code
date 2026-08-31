import Foundation

enum AnimationCompilerError: LocalizedError {
    case projectNotReady
    case unvalidatedAsset(String)
    case missingLoop(String)
    case missingFile(String)
    case checksumMismatch(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .projectNotReady: t("creator.error.project_not_ready")
        case .unvalidatedAsset(let asset): String(format: t("creator.error.unvalidated_asset"), asset)
        case .missingLoop(let state): String(format: t("creator.error.missing_loop"), state)
        case .missingFile(let path): String(format: t("creator.error.missing_file"), path)
        case .checksumMismatch(let path): String(format: t("creator.error.runtime_checksum"), path)
        case .unsafePath(let path): String(format: t("creator.error.unsafe_asset_path"), path)
        }
    }
}

struct AnimationCompiler {
    static let runtimeVersion = "2.0-creator"

    func compile(project: MascotProject, projectDirectory: URL) throws -> PeachyAnimationConfig {
        guard project.status == .ready else { throw AnimationCompilerError.projectNotReady }
        try validateAssets(project: project, projectDirectory: projectDirectory)

        let nodes = try project.states.map { state in
            PeachyAnimationNode(
                id: state.id,
                name: state.name,
                transparentThumbnailUrl: try state.anchor.map {
                    try assetURL($0, projectDirectory: projectDirectory).absoluteString
                }
            )
        }

        var edges: [PeachyAnimationEdge] = []
        for state in project.states {
            guard let loop = state.loop else { throw AnimationCompilerError.missingLoop(state.name) }
            let url = try assetURL(loop, projectDirectory: projectDirectory)
            edges.append(
                PeachyAnimationEdge(
                    id: "\(state.id)-loop",
                    source: state.id,
                    target: state.id,
                    isLoop: true,
                    duration: state.loopDuration,
                    conditions: [],
                    videos: PeachyAnimationVideos(webm: nil, hevc: url.absoluteString),
                    priority: nil,
                    speed: nil,
                    sound: nil
                )
            )
        }

        for transition in project.transitions {
            guard let video = transition.video else { continue }
            let url = try assetURL(video, projectDirectory: projectDirectory)
            let activationInput = project.states.first(where: { $0.id == transition.target })?.activationInput
                ?? "creator::\(transition.target)"
            edges.append(
                PeachyAnimationEdge(
                    id: transition.id,
                    source: transition.source,
                    target: transition.target,
                    isLoop: false,
                    duration: transition.duration,
                    conditions: [PeachyAnimationCondition(input: activationInput, value: .bool(true))],
                    videos: PeachyAnimationVideos(webm: nil, hevc: url.absoluteString),
                    priority: nil,
                    speed: nil,
                    sound: nil
                )
            )
        }

        for state in project.states {
            let template = MascotStateTemplate(rawValue: state.id)
            edges.append(
                PeachyAnimationEdge(
                    id: "creator-route-\(state.id)",
                    source: "*",
                    target: state.id,
                    isLoop: false,
                    duration: 0,
                    conditions: [PeachyAnimationCondition(input: state.activationInput, value: .bool(true))],
                    videos: PeachyAnimationVideos(webm: nil, hevc: nil),
                    priority: template?.routingPriority ?? 0,
                    speed: nil,
                    sound: nil
                )
            )
        }

        return PeachyAnimationConfig(
            version: Self.runtimeVersion,
            name: project.name,
            initialNode: project.states.first(where: { $0.id == MascotStateTemplate.idle.id })?.id
                ?? project.states[0].id,
            autoPlay: true,
            nodes: nodes,
            edges: edges,
            inputs: nil
        )
    }

    private func validateAssets(project: MascotProject, projectDirectory: URL) throws {
        for state in project.states {
            guard let anchor = state.anchor else {
                throw AnimationCompilerError.unvalidatedAsset("\(state.name) anchor")
            }
            guard state.validation?.passed == true else {
                throw AnimationCompilerError.unvalidatedAsset("\(state.name) loop")
            }
            try verify(anchor, projectDirectory: projectDirectory)
            guard let loop = state.loop else { throw AnimationCompilerError.missingLoop(state.name) }
            try verify(loop, projectDirectory: projectDirectory)
        }
        for transition in project.transitions {
            guard transition.validation?.passed == true, let video = transition.video else {
                throw AnimationCompilerError.unvalidatedAsset(transition.id)
            }
            try verify(video, projectDirectory: projectDirectory)
        }
        if let reference = project.reference { try verify(reference, projectDirectory: projectDirectory) }
        if let styleReference = project.styleReference { try verify(styleReference, projectDirectory: projectDirectory) }
    }

    private func verify(_ asset: MascotAsset, projectDirectory: URL) throws {
        let url = try assetURL(asset, projectDirectory: projectDirectory)
        guard MascotProjectStore.sha256(fileAt: url) == asset.sha256 else {
            throw AnimationCompilerError.checksumMismatch(asset.relativePath)
        }
    }

    private func assetURL(_ asset: MascotAsset, projectDirectory: URL) throws -> URL {
        let url = try SafeFileTree.safeURL(
            relativePath: asset.relativePath,
            under: projectDirectory,
            resolveSymlinks: true,
            invalidPath: AnimationCompilerError.unsafePath
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AnimationCompilerError.missingFile(asset.relativePath)
        }
        return url
    }
}
