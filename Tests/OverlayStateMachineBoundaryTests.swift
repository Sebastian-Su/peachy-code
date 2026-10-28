import XCTest
@testable import PeachyPet

final class OverlayStateMachineBoundaryTests: XCTestCase {
    @MainActor
    func testStateTransitionWaitsForLoopBoundary() {
        let config = PeachyAnimationConfig(
            version: AnimationCompiler.runtimeVersion,
            name: "Boundary",
            initialNode: "idle",
            autoPlay: true,
            nodes: [
                PeachyAnimationNode(id: "idle", name: "Idle", transparentThumbnailUrl: nil),
                PeachyAnimationNode(id: "working", name: "Working", transparentThumbnailUrl: nil),
            ],
            edges: [
                edge(id: "idle-loop", source: "idle", target: "idle", loop: true, condition: nil),
                edge(id: "working-loop", source: "working", target: "working", loop: true, condition: nil),
                edge(
                    id: "idle-working",
                    source: "idle",
                    target: "working",
                    loop: false,
                    condition: PeachyAnimationCondition(input: "agent::isWorking", value: .bool(true))
                ),
            ],
            inputs: nil
        )
        let machine = OverlayStateMachine(config: config)
        machine.start()
        let loopURL = machine.currentVideoURL

        machine.setAgentStateInput("isWorking", .bool(true))

        XCTAssertEqual(machine.phase, .looping)
        XCTAssertEqual(machine.currentVideoURL, loopURL)

        machine.handleLoopCycleCompleted()

        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("idle-working.mov") == true)
    }

    @MainActor
    func testLegacyMascotTransitionWaitsForLoopBoundary() {
        let machine = OverlayStateMachine(config: legacyConfig())
        machine.start()
        let loopURL = machine.currentVideoURL

        machine.setAgentStateInput("isWorking", .bool(true))

        XCTAssertEqual(machine.phase, .looping)
        XCTAssertEqual(machine.currentVideoURL, loopURL)

        machine.handleLoopCycleCompleted()

        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("idle-working.mov") == true)
    }

    @MainActor
    func testStateUndoneBeforeLoopBoundaryNeverPlays() {
        let machine = OverlayStateMachine(config: legacyConfig())
        machine.start()
        let loopURL = machine.currentVideoURL

        machine.setAgentStateInput("isWorking", .bool(true))
        machine.setAgentStateInput("isWorking", .bool(false))
        machine.handleLoopCycleCompleted()

        XCTAssertEqual(machine.phase, .looping)
        XCTAssertEqual(machine.currentNodeId, "idle")
        XCTAssertEqual(machine.currentVideoURL, loopURL)
    }

    @MainActor
    func testArrivalStartsMatchingTransitionWithoutPlayingLoop() {
        let machine = OverlayStateMachine(config: legacyConfig())
        machine.start()
        machine.setAgentStateInput("isWorking", .bool(true))
        machine.handleLoopCycleCompleted()

        // Working is reached while the agent already went idle again.
        machine.setAgentStateInput("isWorking", .bool(false))
        machine.handleVideoEnded()

        XCTAssertEqual(machine.currentNodeId, "working")
        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("working-idle.mov") == true)
    }

    @MainActor
    func testClickStartsTransitionAtOnce() {
        var config = legacyConfig()
        config.edges.append(
            edge(id: "idle-poke", source: "idle", target: "working", loop: false,
                 condition: PeachyAnimationCondition(input: "clicked", value: .bool(true)))
        )
        let machine = OverlayStateMachine(config: config)
        machine.start()

        machine.handleClick()

        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("idle-poke.mov") == true)
    }

    private func legacyConfig() -> PeachyAnimationConfig {
        PeachyAnimationConfig(
            version: "2.0",
            name: "Legacy",
            initialNode: "idle",
            autoPlay: true,
            nodes: [
                PeachyAnimationNode(id: "idle", name: "Idle", transparentThumbnailUrl: nil),
                PeachyAnimationNode(id: "working", name: "Working", transparentThumbnailUrl: nil),
            ],
            edges: [
                edge(id: "idle-loop", source: "idle", target: "idle", loop: true, condition: nil),
                edge(id: "working-loop", source: "working", target: "working", loop: true, condition: nil),
                edge(
                    id: "idle-working",
                    source: "idle",
                    target: "working",
                    loop: false,
                    condition: PeachyAnimationCondition(input: "agent::isWorking", value: .bool(true))
                ),
                edge(
                    id: "working-idle",
                    source: "working",
                    target: "idle",
                    loop: false,
                    condition: PeachyAnimationCondition(input: "agent::isWorking", value: .bool(false))
                ),
            ],
            inputs: nil
        )
    }

    private func edge(
        id: String,
        source: String,
        target: String,
        loop: Bool,
        condition: PeachyAnimationCondition?
    ) -> PeachyAnimationEdge {
        PeachyAnimationEdge(
            id: id,
            source: source,
            target: target,
            isLoop: loop,
            duration: 1,
            conditions: condition.map { [$0] } ?? [],
            videos: PeachyAnimationVideos(webm: nil, hevc: "file:///tmp/\(id).mov"),
            priority: nil,
            speed: nil,
            sound: nil
        )
    }
}
