import XCTest
import AppKit
@testable import PeachyPet

@MainActor
final class SpritePetPlaybackTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spriteplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func installedConfig(frames: [Int] = [6, 8, 8, 4, 5, 8, 6, 6, 6]) throws -> PeachyAnimationConfig {
        let pack = tmp.appendingPathComponent("pack")
        try writeSpritePack(frames: frames, in: pack)
        return try SpritePetInstaller.install(directory: pack, source: .local, into: tmp.appendingPathComponent("Pets")).config
    }

    private func node(_ name: String, _ config: PeachyAnimationConfig) -> String {
        config.nodes.first { $0.name == name }!.id
    }

    // P2: the sprite pet starts looping its idle row instead of sitting with no video
    func testSpritePetLoopsIdleRowOnStart() throws {
        let config = try installedConfig()
        let machine = OverlayStateMachine(config: config)
        machine.start()
        XCTAssertEqual(machine.phase, .looping)
        XCTAssertEqual(machine.currentNodeId, node("Idle", config))
        XCTAssertEqual(machine.currentSpriteRow, 0)
        XCTAssertNil(machine.currentVideoURL)
    }

    // S20
    func testFrameRatesPerState() throws {
        let config = try installedConfig()
        XCTAssertEqual(SpriteTiming.fps(for: node("Working", config), in: config), 8)
        XCTAssertEqual(SpriteTiming.fps(for: node("Needs Attention", config), in: config), 4)
        XCTAssertEqual(SpriteTiming.fps(for: node("Idle", config), in: config), 3)
        XCTAssertEqual(SpriteTiming.fps(for: node("Thinking", config), in: config), 3)
    }

    // S21: one integer scale for every frame of the pet, bottom-centred, whole pixels
    func testOneIntegerScaleForTheWholePet() {
        let frames = [CGSize(width: 136, height: 198), CGSize(width: 182, height: 198), CGSize(width: 150, height: 190)]
        let layout = SpriteLayout(frameSizes: frames, canvas: CGSize(width: 600, height: 600))
        XCTAssertEqual(layout.scale, 3, "600 / 198 = 3.03, floored to 3")
        for size in frames {
            let rect = layout.rect(for: size)
            XCTAssertEqual(rect.width, size.width * 3)
            XCTAssertEqual(rect.minY, 600 - size.height * 3, "bottom aligned in flipped coordinates")
            XCTAssertEqual(rect.minX, rect.minX.rounded(), "whole pixels")
        }
    }

    func testCanvasSmallerThanFrameShrinksWithoutRounding() {
        let layout = SpriteLayout(frameSizes: [CGSize(width: 200, height: 200)], canvas: CGSize(width: 100, height: 100))
        XCTAssertEqual(layout.scale, 0.5)
    }

    // S19 (P3): state changes wait for the end of the loop, then hard-cut to the target row
    func testStateChangeWaitsForLoopEndThenCuts() throws {
        let config = try installedConfig()
        let machine = OverlayStateMachine(config: config)
        machine.start()
        machine.setAgentStateInput("isIdle", .bool(false))
        machine.setAgentStateInput("isAlert", .bool(true))
        XCTAssertEqual(machine.currentNodeId, node("Idle", config), "still finishing the idle loop")
        machine.handleLoopCycleCompleted()
        XCTAssertEqual(machine.currentNodeId, node("Needs Attention", config))
        XCTAssertEqual(machine.phase, .looping)
        XCTAssertEqual(machine.currentSpriteRow, 6)
    }

    func testStateUndoneBeforeLoopEndNeverPlays() throws {
        let config = try installedConfig()
        let machine = OverlayStateMachine(config: config)
        machine.start()
        machine.setAgentStateInput("isAlert", .bool(true))
        machine.setAgentStateInput("isAlert", .bool(false))
        machine.handleLoopCycleCompleted()
        XCTAssertEqual(machine.currentNodeId, node("Idle", config))
    }

    // S16
    func testEachStatePlaysItsRow() throws {
        let config = try installedConfig()
        let machine = OverlayStateMachine(config: config)
        machine.start()
        machine.setAgentStateInput("isIdle", .bool(false))
        machine.setAgentStateInput("isCompacting", .bool(true))
        machine.handleLoopCycleCompleted()
        XCTAssertEqual(machine.currentNodeId, node("Thinking", config))
        XCTAssertEqual(machine.currentSpriteRow, 8)
        machine.setAgentStateInput("isCompacting", .bool(false))
        machine.setAgentStateInput("isWorking", .bool(true))
        machine.handleLoopCycleCompleted()
        XCTAssertEqual(machine.currentNodeId, node("Working", config))
        XCTAssertTrue([7, 1, 2].contains(machine.currentSpriteRow ?? -1))
    }

    // S17: working re-picks among its three rows every loop
    func testWorkingPicksRunRowsAtRandomEachLoop() throws {
        let config = try installedConfig()
        var generator = SeededGenerator(seed: 42)
        let machine = OverlayStateMachine(config: config, random: { generator.next() })
        machine.start()
        machine.setAgentStateInput("isIdle", .bool(false))
        machine.setAgentStateInput("isWorking", .bool(true))
        var seen = Set<Int>()
        for _ in 0..<30 {
            machine.handleLoopCycleCompleted()
            seen.insert(try XCTUnwrap(machine.currentSpriteRow))
        }
        XCTAssertEqual(seen, [7, 1, 2])
    }

    func testWorkingWithMissingRunRowsUsesWhatIsLeft() throws {
        let config = try installedConfig(frames: [6, 0, 8, 4, 5, 8, 6, 0, 6])
        XCTAssertEqual(config.sprite?.rows[node("Working", config)], [2])
        let none = try installedConfig(frames: [6, 0, 0, 4, 5, 8, 6, 0, 6])
        XCTAssertEqual(none.sprite?.rows[node("Working", none)], [0])
    }

    // S25: video pets keep their path
    func testVideoPetHasNoSpriteRow() {
        let json = #"{"version":"2.0","name":"V","initialNode":"idle","autoPlay":true,"nodes":[{"id":"idle","name":"Idle"}],"edges":[{"id":"l","source":"idle","target":"idle","isLoop":true,"duration":4,"videos":{"hevc":"file:///tmp/idle.mov"}}]}"#
        let config = try! JSONDecoder().decode(PeachyAnimationConfig.self, from: Data(json.utf8))
        let machine = OverlayStateMachine(config: config)
        machine.start()
        XCTAssertNil(machine.currentSpriteRow)
        XCTAssertNotNil(machine.currentVideoURL)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@MainActor
final class SpriteSheetViewTests: XCTestCase {
    // P2/P3: the view reports each finished pass, then shows the state machine's new row
    func testViewAdvancesFramesAndCutsAtTheLoopEnd() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spriteview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeSpritePack(frames: [3, 8, 8, 4, 5, 8, 2, 6, 6], in: tmp.appendingPathComponent("pack"))
        let config = try SpritePetInstaller.install(directory: tmp.appendingPathComponent("pack"), source: .local, into: tmp.appendingPathComponent("Pets")).config
        let machine = OverlayStateMachine(config: config)
        machine.start()
        let view = SpriteSheetView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        view.stateMachine = machine
        view.reload()
        let first = view.frameLayer.contents as AnyObject?
        XCTAssertNotNil(first)
        view.advance()
        XCTAssertFalse((view.frameLayer.contents as AnyObject?) === first, "next frame")
        let size = view.frameLayer.frame.size

        machine.setAgentStateInput("isIdle", .bool(false))
        machine.setAgentStateInput("isAlert", .bool(true))
        view.advance(); view.advance() // 3rd idle frame was shown; this ends the pass
        XCTAssertEqual(machine.currentSpriteRow, 6)
        XCTAssertEqual(view.frameLayer.frame.size, size, "same scale after switching state")
        XCTAssertEqual(view.frameLayer.magnificationFilter, .nearest)
        view.teardown()
    }
}
