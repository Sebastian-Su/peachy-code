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
    func testLegacyMascotTransitionStartsImmediately() {
        let config = PeachyAnimationConfig(
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
            ],
            inputs: nil
        )
        let machine = OverlayStateMachine(config: config)
        machine.start()

        machine.setAgentStateInput("isWorking", .bool(true))

        XCTAssertEqual(machine.phase, .transitioning)
        XCTAssertTrue(machine.currentVideoURL?.absoluteString.contains("idle-working.mov") == true)
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
