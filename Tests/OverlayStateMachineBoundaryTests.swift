import AVFoundation
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

    /// The queued transition is published so the view can decode it before the loop ends.
    @MainActor
    func testQueuedTransitionIsPublishedUntilItStarts() {
        let machine = OverlayStateMachine(config: legacyConfig())
        machine.start()
        XCTAssertNil(machine.upcomingVideoURL)

        machine.setAgentStateInput("isWorking", .bool(true))
        XCTAssertTrue(machine.upcomingVideoURL?.absoluteString.contains("idle-working.mov") == true)

        machine.setAgentStateInput("isWorking", .bool(false))
        XCTAssertNil(machine.upcomingVideoURL)

        machine.setAgentStateInput("isWorking", .bool(true))
        machine.handleLoopCycleCompleted()
        XCTAssertNil(machine.upcomingVideoURL)
        XCTAssertEqual(machine.currentVideoURL?.lastPathComponent, "idle-working.mov")
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

    /// `duration` must not stretch a clip: a 1 s file with duration 4 still plays at its speed.
    @MainActor
    func testPlaybackRateIgnoresDuration() async throws {
        let clip = FileManager.default.temporaryDirectory
            .appendingPathComponent("rate-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: clip) }
        try await writeOneSecondClip(to: clip)

        func config(speed: Double?) -> PeachyAnimationConfig {
            PeachyAnimationConfig(
                version: "2.0", name: "Rate", initialNode: "idle", autoPlay: true,
                nodes: [PeachyAnimationNode(id: "idle", name: "Idle", transparentThumbnailUrl: nil)],
                edges: [PeachyAnimationEdge(
                    id: "idle-loop", source: "idle", target: "idle", isLoop: true, duration: 4,
                    conditions: [], videos: PeachyAnimationVideos(webm: nil, hevc: clip.absoluteString),
                    priority: nil, speed: speed, sound: nil
                )],
                inputs: nil
            )
        }

        let plain = OverlayStateMachine(config: config(speed: nil))
        plain.start()
        XCTAssertEqual(plain.currentPlaybackRate, 1)

        let fast = OverlayStateMachine(config: config(speed: 2))
        fast.start()
        XCTAssertEqual(fast.currentPlaybackRate, 2)
    }

    private func writeOneSecondClip(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        for frame in 0...10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
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
