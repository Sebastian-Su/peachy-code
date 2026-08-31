import XCTest
@testable import PeachyPet

final class MascotGenerationPipelineTests: XCTestCase {
    func testPipelineCompletesAndResumeSkipsFinishedAssets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MascotGenerationPipelineTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MascotProjectStore(rootURL: root)
        var project = try store.createProject(name: "PeachMilky", stylePrompt: "ink", states: [.idle, .working])
        project.removeFlatBackground = false
        project.reference = try store.writeAsset(
            Data("reference".utf8),
            relativePath: "character/reference.png",
            mediaType: .image,
            projectID: project.id
        )
        try store.save(project)

        let provider = FixtureMediaProvider()
        let pipeline = MascotGenerationPipeline(store: store, provider: provider, validator: AcceptingMediaValidator())
        let completed = try await pipeline.generate(projectID: project.id)
        let firstCallCount = provider.callCount
        _ = try await pipeline.generate(projectID: project.id)

        XCTAssertEqual(completed.status, .ready)
        XCTAssertTrue(completed.states.allSatisfy { $0.anchor != nil && $0.loop != nil })
        XCTAssertTrue(completed.transitions.allSatisfy { $0.video != nil })
        XCTAssertEqual(provider.callCount, firstCallCount, "Resume should not regenerate completed assets")
    }
}

private final class FixtureMediaProvider: MediaGenerationProvider {
    let id = "fixture"
    let displayName = "Fixture"
    private(set) var callCount = 0

    func generateAnchor(request: AnchorGenerationRequest) async throws -> GeneratedMedia {
        callCount += 1
        return GeneratedMedia(data: Data("anchor-\(request.state.id)".utf8), fileExtension: "png", mediaType: .image)
    }

    func generateLoop(request: LoopGenerationRequest) async throws -> GeneratedMedia {
        callCount += 1
        return GeneratedMedia(data: Data("loop-\(request.state.id)".utf8), fileExtension: "mov", mediaType: .video)
    }

    func generateTransition(request: TransitionGenerationRequest) async throws -> GeneratedMedia {
        callCount += 1
        return GeneratedMedia(data: Data("transition-\(request.transition.id)".utf8), fileExtension: "mov", mediaType: .video)
    }
}

private struct AcceptingMediaValidator: MascotMediaValidating {
    func validateImage(at url: URL) throws -> MascotMediaValidation {
        MascotMediaValidation(passed: true, seamScore: nil, messages: [])
    }

    func validateLoop(videoURL: URL, anchorURL: URL) async throws -> MascotMediaValidation {
        MascotMediaValidation(passed: true, seamScore: 1, messages: [])
    }

    func validateTransition(videoURL: URL, sourceAnchorURL: URL, targetAnchorURL: URL) async throws -> MascotMediaValidation {
        MascotMediaValidation(passed: true, seamScore: 1, messages: [])
    }
}
