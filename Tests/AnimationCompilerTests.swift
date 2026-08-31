import XCTest
@testable import PeachyPet

final class AnimationCompilerTests: XCTestCase {
    func testCompilerProducesLocalLoopAndIdleHubEdges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimationCompilerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let loop = MascotAsset(relativePath: "states/idle/loop.mov", sha256: "loop", mediaType: .video)
        let transition = MascotAsset(relativePath: "transitions/idle__working/clip.mov", sha256: "transition", mediaType: .video)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("states/idle"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("transitions/idle__working"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(loop.relativePath))
        try Data().write(to: root.appendingPathComponent(transition.relativePath))

        var project = MascotProject.make(name: "PeachMilky", stylePrompt: "ink", states: [.idle, .working])
        project.states[0].loop = loop
        project.states[0].anchor = MascotAsset(relativePath: "states/idle/anchor.png", sha256: "", mediaType: .image)
        project.states[0].validation = passedValidation
        project.states[1].loop = MascotAsset(relativePath: "states/working/loop.mov", sha256: "working", mediaType: .video)
        project.states[1].anchor = MascotAsset(relativePath: "states/working/anchor.png", sha256: "", mediaType: .image)
        project.states[1].validation = passedValidation
        try FileManager.default.createDirectory(at: root.appendingPathComponent("states/working"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("states/working/loop.mov"))
        try Data().write(to: root.appendingPathComponent("states/idle/anchor.png"))
        try Data().write(to: root.appendingPathComponent("states/working/anchor.png"))
        for index in project.transitions.indices {
            project.transitions[index].video = transition
            project.transitions[index].validation = passedValidation
        }
        project = try projectWithCurrentHashes(project, root: root)
        project.status = .ready

        let config = try AnimationCompiler().compile(project: project, projectDirectory: root)

        XCTAssertEqual(config.nodes.count, 2)
        XCTAssertEqual(config.edges.filter(\.isLoop).count, 2)
        XCTAssertEqual(config.version, AnimationCompiler.runtimeVersion)
        XCTAssertEqual(config.edges.filter { $0.source == "*" }.count, 2)
        XCTAssertTrue(config.edges.contains {
            $0.source == "*"
                && $0.target == "working"
                && $0.conditions?.first?.input == "agent::isWorking"
        })
        XCTAssertTrue(config.edges.compactMap(\.videos.hevc).allSatisfy { $0.hasPrefix("file://") })
    }

    @MainActor
    func testCompiledIdleHubRoutesBetweenNonIdleStates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimationCompilerRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var project = MascotProject.make(
            name: "Router",
            stylePrompt: "test",
            states: [.idle, .working, .thinking]
        )
        for index in project.states.indices {
            let path = "states/\(project.states[index].id)/loop.mov"
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent(path))
            project.states[index].loop = MascotAsset(relativePath: path, sha256: path, mediaType: .video)
            let anchorPath = "states/\(project.states[index].id)/anchor.png"
            try Data().write(to: root.appendingPathComponent(anchorPath))
            project.states[index].anchor = MascotAsset(relativePath: anchorPath, sha256: anchorPath, mediaType: .image)
            project.states[index].validation = passedValidation
        }
        for index in project.transitions.indices {
            let path = "transitions/\(project.transitions[index].id)/clip.mov"
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent(path))
            project.transitions[index].video = MascotAsset(relativePath: path, sha256: path, mediaType: .video)
            project.transitions[index].validation = passedValidation
        }
        project = try projectWithCurrentHashes(project, root: root)
        project.status = .ready

        let machine = OverlayStateMachine(config: try AnimationCompiler().compile(project: project, projectDirectory: root))
        machine.start()
        machine.setAgentStateInput("isWorking", .bool(true))
        machine.setAgentStateInput("isIdle", .bool(false))
        machine.handleLoopCycleCompleted()
        machine.handleVideoEnded()
        XCTAssertEqual(machine.currentNodeId, "working")

        machine.setAgentStateInput("isWorking", .bool(false))
        machine.setAgentStateInput("isCompacting", .bool(true))
        machine.handleLoopCycleCompleted()
        machine.handleVideoEnded()
        XCTAssertEqual(machine.currentNodeId, "idle")
        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("idle__thinking") == true)
        machine.handleVideoEnded()
        XCTAssertEqual(machine.currentNodeId, "thinking")

        machine.setAgentStateInput("isCompacting", .bool(false))
        machine.setAgentStateInput("isWorking", .bool(true))
        machine.handleLoopCycleCompleted()
        machine.setAgentStateInput("isWorking", .bool(false))
        machine.setAgentStateInput("isCompacting", .bool(true))
        machine.handleVideoEnded()
        XCTAssertEqual(machine.currentNodeId, "idle")
        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("idle__thinking") == true)
        machine.handleVideoEnded()
        XCTAssertEqual(machine.currentNodeId, "thinking")
    }

    func testCompilerRejectsTamperedReadyProjectAsset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimationCompilerIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("states/idle"), withIntermediateDirectories: true)
        let anchorPath = "states/idle/anchor.png"
        let loopPath = "states/idle/loop.mov"
        try Data("anchor".utf8).write(to: root.appendingPathComponent(anchorPath))
        try Data("loop".utf8).write(to: root.appendingPathComponent(loopPath))

        var project = MascotProject.make(name: "Integrity", stylePrompt: "", states: [.idle])
        project.states[0].anchor = MascotAsset(relativePath: anchorPath, sha256: "", mediaType: .image)
        project.states[0].loop = MascotAsset(relativePath: loopPath, sha256: "", mediaType: .video)
        project.states[0].validation = passedValidation
        project = try projectWithCurrentHashes(project, root: root)
        project.status = .ready
        try Data("tampered".utf8).write(to: root.appendingPathComponent(loopPath))

        XCTAssertThrowsError(try AnimationCompiler().compile(project: project, projectDirectory: root))
    }

    private var passedValidation: MascotMediaValidation {
        MascotMediaValidation(passed: true, seamScore: 1, messages: [])
    }

    private func projectWithCurrentHashes(_ project: MascotProject, root: URL) throws -> MascotProject {
        var value = project
        for index in value.states.indices {
            if let anchor = value.states[index].anchor {
                value.states[index].anchor = try assetWithCurrentHash(anchor, root: root)
            }
            if let loop = value.states[index].loop {
                value.states[index].loop = try assetWithCurrentHash(loop, root: root)
            }
        }
        for index in value.transitions.indices {
            if let video = value.transitions[index].video {
                value.transitions[index].video = try assetWithCurrentHash(video, root: root)
            }
        }
        return value
    }

    private func assetWithCurrentHash(_ asset: MascotAsset, root: URL) throws -> MascotAsset {
        MascotAsset(
            relativePath: asset.relativePath,
            sha256: MascotProjectStore.sha256(try Data(contentsOf: root.appendingPathComponent(asset.relativePath))),
            mediaType: asset.mediaType
        )
    }
}
