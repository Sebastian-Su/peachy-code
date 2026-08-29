import AppKit
import AVFoundation
import XCTest
@testable import PeachyPet

final class MockMediaProviderIntegrationTests: XCTestCase {
    func testMockProviderProducesValidatedPlayableLocalMasko() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockMediaProviderIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MascotProjectStore(rootURL: root)
        var project = try store.createProject(name: "Mock", stylePrompt: "test", states: [.idle])
        project.reference = try store.writeAsset(
            try referencePNG(),
            relativePath: "character/reference.png",
            mediaType: .image,
            projectID: project.id
        )
        try store.save(project)

        let completed = try await MascotGenerationPipeline(
            store: store,
            provider: MockMediaGenerationProvider()
        ).generate(projectID: project.id)
        let loop = try XCTUnwrap(completed.states.first?.loop, "blocks: \(completed.blocks)")
        let loopURL = try store.assetURL(loop, projectID: completed.id)
        let duration = try await AVURLAsset(url: loopURL).load(.duration)
        let validation = try await MediaValidator().validateLoop(
            videoURL: loopURL,
            anchorURL: try store.assetURL(try XCTUnwrap(completed.states.first?.anchor), projectID: completed.id)
        )

        XCTAssertEqual(completed.status, .ready)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
        XCTAssertTrue(loopURL.isFileURL)
        XCTAssertTrue(validation.passed)
    }

    private func referencePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSColor.systemPink.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 48, height: 48)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MockMediaProviderIntegrationTests", code: 1)
        }
        return png
    }
}
