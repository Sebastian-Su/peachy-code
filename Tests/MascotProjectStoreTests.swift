import XCTest
@testable import PeachyPet

final class MascotProjectStoreTests: XCTestCase {
    func testProjectCanBeCreatedSavedAndRestoredWithLocalReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MascotProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MascotProjectStore(rootURL: root)
        var project = try store.createProject(
            name: "PeachMilky",
            stylePrompt: "soft clay",
            states: [.idle, .working, .thinking]
        )
        project.reference = try store.writeAsset(
            Data("reference-image".utf8),
            relativePath: "character/reference.png",
            mediaType: .image,
            projectID: project.id
        )
        try store.save(project)

        let restored = MascotProjectStore(rootURL: root).project(id: project.id)

        XCTAssertEqual(restored?.name, "PeachMilky")
        XCTAssertEqual(restored?.states.map(\.id), ["idle", "working", "thinking"])
        XCTAssertEqual(restored?.transitions.count, 4, "MVP should create Idle hub transitions only")
        XCTAssertEqual(restored?.reference?.relativePath, "character/reference.png")
    }
}
