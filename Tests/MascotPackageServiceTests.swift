import XCTest
@testable import PeachyPet

final class MascotPackageServiceTests: XCTestCase {
    func testExportAndImportPreserveProjectAndAssetIntegrity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MascotPackageServiceTests-\(UUID().uuidString)", isDirectory: true)
        let exportURL = root.appendingPathComponent("PeachMilky.masko", isDirectory: true)
        let restoredRoot = root.appendingPathComponent("restored", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceStore = MascotProjectStore(rootURL: root.appendingPathComponent("source", isDirectory: true))
        var project = try sourceStore.createProject(name: "PeachMilky", stylePrompt: "ink", states: [.idle, .working])
        project.reference = try sourceStore.writeAsset(
            Data("reference".utf8),
            relativePath: "character/reference.png",
            mediaType: .image,
            projectID: project.id
        )
        try sourceStore.save(project)

        let service = MascotPackageService()
        try service.export(project: project, from: sourceStore.projectDirectory(for: project.id), to: exportURL)
        let restoredStore = MascotProjectStore(rootURL: restoredRoot)
        let imported = try service.importPackage(at: exportURL, into: restoredStore)

        XCTAssertEqual(imported.id, project.id)
        XCTAssertEqual(imported.reference?.sha256, project.reference?.sha256)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: restoredStore.projectDirectory(for: imported.id)
                    .appendingPathComponent("character/reference.png").path
            )
        )
    }

    func testImportRejectsTamperedAsset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MascotPackageTamperTests-\(UUID().uuidString)", isDirectory: true)
        let exportURL = root.appendingPathComponent("PeachMilky.masko", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceStore = MascotProjectStore(rootURL: root.appendingPathComponent("source", isDirectory: true))
        var project = try sourceStore.createProject(name: "PeachMilky", stylePrompt: "ink", states: [.idle])
        project.reference = try sourceStore.writeAsset(
            Data("reference".utf8),
            relativePath: "character/reference.png",
            mediaType: .image,
            projectID: project.id
        )
        try sourceStore.save(project)

        let service = MascotPackageService()
        try service.export(project: project, from: sourceStore.projectDirectory(for: project.id), to: exportURL)
        try Data("tampered".utf8).write(to: exportURL.appendingPathComponent("character/reference.png"))

        XCTAssertThrowsError(
            try service.importPackage(
                at: exportURL,
                into: MascotProjectStore(rootURL: root.appendingPathComponent("restored", isDirectory: true))
            )
        )
    }
}
