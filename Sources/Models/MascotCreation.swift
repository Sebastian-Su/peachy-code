import Foundation

enum MascotMediaType: String, Codable {
    case image
    case video
}

struct MascotAsset: Codable, Equatable {
    let relativePath: String
    let sha256: String
    let mediaType: MascotMediaType
}

enum MascotProjectStatus: String, Codable {
    case draft
    case generating
    case needsReview
    case ready
    case blocked
    case failed
}

enum MascotGenerationJobStatus: String, Codable {
    case pending
    case running
    case complete
    case blocked
    case failed
}

enum MascotGenerationJobKind: String, Codable {
    case anchor
    case loop
    case transition
    case validation
}

struct MascotGenerationJob: Identifiable, Codable, Equatable {
    let id: String
    let kind: MascotGenerationJobKind
    let targetID: String
    var status: MascotGenerationJobStatus
    var message: String?
}

struct MascotCreationBlock: Identifiable, Codable, Equatable {
    let id: String
    let message: String
}

struct MascotMediaValidation: Codable, Equatable {
    let passed: Bool
    let seamScore: Double?
    let messages: [String]
}

enum MascotStateTemplate: String, CaseIterable, Codable, Identifiable {
    case idle
    case working
    case thinking
    case needsAttention = "needs-attention"

    var id: String { rawValue }

    private var metadata: (displayName: String, prompt: String, activationInput: String, priority: Int) {
        switch self {
        case .idle:
            ("Idle", "calm idle breathing, subtle natural motion", "agent::isIdle", 100)
        case .working:
            ("Working", "focused working motion, typing and concentrating", "agent::isWorking", 200)
        case .thinking:
            ("Thinking", "thinking, considering an idea, gentle head movement", "agent::isCompacting", 300)
        case .needsAttention:
            ("Needs Attention", "requesting attention, clear but friendly gesture", "agent::isAlert", 400)
        }
    }

    var displayName: String { metadata.displayName }
    var prompt: String { metadata.prompt }
    var activationInput: String { metadata.activationInput }
    var routingPriority: Int { metadata.priority }
}

enum MascotStylePreset: String, CaseIterable, Identifiable {
    case soft3D = "soft-3d"
    case anime
    case ink
    case pixelArt = "pixel-art"
    case clay
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soft3D: "Soft 3D"
        case .anime: "Anime"
        case .ink: "Ink"
        case .pixelArt: "Pixel Art"
        case .clay: "Clay"
        case .custom: "Custom"
        }
    }

    var prompt: String {
        switch self {
        case .soft3D: "soft 3D character, warm studio light, rounded shapes, consistent proportions"
        case .anime: "clean anime character, expressive face, polished cel shading, consistent design"
        case .ink: "hand-drawn ink illustration, restrained colors, textured paper feeling"
        case .pixelArt: "high-quality pixel art character, crisp edges, limited palette, consistent sprite scale"
        case .clay: "handmade clay character, soft tactile texture, gentle lighting, stop-motion feeling"
        case .custom: ""
        }
    }
}

struct MascotStateDraft: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var prompt: String
    var activationInput: String
    var anchor: MascotAsset?
    var loop: MascotAsset?
    var validation: MascotMediaValidation?
    var loopDuration: Double
}

struct MascotTransitionDraft: Identifiable, Codable, Equatable {
    let id: String
    let source: String
    let target: String
    var prompt: String
    var video: MascotAsset?
    var validation: MascotMediaValidation?
    var duration: Double
}

struct MascotProject: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var stylePrompt: String
    var reference: MascotAsset?
    var styleReference: MascotAsset?
    var removeFlatBackground: Bool?
    var providerID: String
    var status: MascotProjectStatus
    var states: [MascotStateDraft]
    var transitions: [MascotTransitionDraft]
    var jobs: [MascotGenerationJob]
    var blocks: [MascotCreationBlock]
    let createdAt: Date
    var updatedAt: Date

    static func make(
        name: String,
        stylePrompt: String,
        states requestedStates: [MascotStateTemplate],
        providerID: String = MockMediaGenerationProvider.providerID
    ) -> MascotProject {
        var templates = requestedStates
        if !templates.contains(.idle) {
            templates.insert(.idle, at: 0)
        }
        var seen = Set<MascotStateTemplate>()
        templates = templates.filter { seen.insert($0).inserted }

        let states = templates.map { template in
            MascotStateDraft(
                id: template.id,
                name: template.displayName,
                prompt: template.prompt,
                activationInput: template.activationInput,
                anchor: nil,
                loop: nil,
                validation: nil,
                loopDuration: 4
            )
        }

        let transitions = templates
            .filter { $0 != .idle }
            .flatMap { template in
                [
                    MascotTransitionDraft(
                        id: "idle__\(template.id)",
                        source: MascotStateTemplate.idle.id,
                        target: template.id,
                        prompt: "transition naturally from Idle to \(template.displayName)",
                        video: nil,
                        validation: nil,
                        duration: 1.5
                    ),
                    MascotTransitionDraft(
                        id: "\(template.id)__idle",
                        source: template.id,
                        target: MascotStateTemplate.idle.id,
                        prompt: "transition naturally from \(template.displayName) to Idle",
                        video: nil,
                        validation: nil,
                        duration: 1.5
                    ),
                ]
            }

        let now = Date()
        return MascotProject(
            id: UUID(),
            name: name,
            stylePrompt: stylePrompt,
            reference: nil,
            styleReference: nil,
            removeFlatBackground: true,
            providerID: providerID,
            status: .draft,
            states: states,
            transitions: transitions,
            jobs: [],
            blocks: [],
            createdAt: now,
            updatedAt: now
        )
    }
}
