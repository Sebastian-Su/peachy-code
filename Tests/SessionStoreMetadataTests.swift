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

    private func makeSession(
        projectName: String? = "masko-code",
        sessionTitle: String? = nil,
        projectDisplayName: String? = nil,
        firstUserPrompt: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: "session-1",
            projectDir: "/tmp/masko-code",
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
