import XCTest
@testable import PeachyPet

final class MascotPosterTests: XCTestCase {
    private func config(thumbnail: String?, idleVideo: PeachyAnimationVideos) -> PeachyAnimationConfig {
        let json: [String: Any] = [
            "version": "2.0", "name": "Test", "initialNode": "idle", "autoPlay": true,
            "nodes": [["id": "idle", "name": "Idle", "transparentThumbnailUrl": thumbnail as Any]],
            "edges": [
                ["id": "e1", "source": "idle", "target": "work", "isLoop": false, "duration": 1,
                 "videos": ["hevc": "file:///tmp/transition.mov"]],
                ["id": "e2", "source": "idle", "target": "idle", "isLoop": true, "duration": 1,
                 "videos": ["hevc": idleVideo.hevc as Any, "webm": idleVideo.webm as Any]],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(PeachyAnimationConfig.self, from: data)
    }

    func testUsesThumbnailWhenPresent() {
        let c = config(thumbnail: "https://example.com/idle.png", idleVideo: .init(webm: nil, hevc: "file:///tmp/idle.mov"))
        XCTAssertEqual(MascotPoster.source(for: c), .image(URL(string: "https://example.com/idle.png")!))
    }

    func testVideoOnlyMascotUsesIdleLoopFrame() {
        let c = config(thumbnail: nil, idleVideo: .init(webm: nil, hevc: "file:///tmp/idle.mov"))
        XCTAssertEqual(MascotPoster.source(for: c), .videoFrame(URL(string: "file:///tmp/idle.mov")!))
    }

    func testNoUsableMediaGivesNoPoster() {
        let c = config(thumbnail: nil, idleVideo: .init(webm: nil, hevc: nil))
        XCTAssertNil(MascotPoster.source(for: c))
    }
}
