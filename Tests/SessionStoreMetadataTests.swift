import XCTest
@testable import PeachyPet

final class SessionStoreMetadataTests: XCTestCase {
    func testAgentSessionDisplayUsesProjectOverrideThenProjectName() {
        let overridden = makeSession(
            projectName: "masko-code",
            projectDisplayName: "namiwork-core"
        )
        let fallback = makeSession(projectName: "masko-code")

        XCTAssertEqual(overridden.displayProjectName, "namiwork-core")
        XCTAssertEqual(fallback.displayProjectName, "masko-code")
    }

    func testAgentSessionDisplayUsesTitleThenFirstPrompt() {
        let titled = makeSession(
            sessionTitle: "解决 release 分支冲突",
            firstUserPrompt: "检查 release 分支"
        )
        let fallback = makeSession(firstUserPrompt: "解决 release 分支冲突")

        XCTAssertEqual(titled.displaySessionTitle, "解决 release 分支冲突")
        XCTAssertEqual(fallback.displaySessionTitle, "解决 release 分支冲突")
    }

    func testAgentSessionDisplayOmitsEmptyTitleSeparator() {
        let session = makeSession(sessionTitle: " \n ", firstUserPrompt: "\t")

        XCTAssertNil(session.displaySessionTitle)
    }

    // MARK: - Bug 1: whitespace sessionTitle must not suppress a valid firstUserPrompt

    func testWhitespaceTitleFallsBackToFirstPrompt() {
        let session = makeSession(sessionTitle: "  \n  ", firstUserPrompt: "解决 release 分支冲突")

        XCTAssertEqual(session.displaySessionTitle, "解决 release 分支冲突")
    }

    // MARK: - Bug 2: empty/whitespace project name strings must fall through to "Session"

    func testEmptyProjectNameFallsThrough() {
        let session = makeSession(projectDir: nil, projectName: "")

        XCTAssertEqual(session.displayProjectName, "Session")
    }

    func testRootProjectDirFallsThrough() {
        let session = AgentSession(
            id: "session-root",
            projectDir: "/",
            projectName: nil,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        )

        XCTAssertEqual(session.displayProjectName, "Session")
    }

    private func makeSession(
        projectDir: String? = "/tmp/masko-code",
        projectName: String? = "masko-code",
        sessionTitle: String? = nil,
        projectDisplayName: String? = nil,
        firstUserPrompt: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: "session-1",
            projectDir: projectDir,
            projectName: projectName,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date(),
            sessionTitle: sessionTitle,
            projectDisplayName: projectDisplayName,
            firstUserPrompt: firstUserPrompt
        )
    }
}
