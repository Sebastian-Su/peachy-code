import Foundation
import XCTest
@testable import PeachyPet

final class IDETerminalFocusTests: XCTestCase {
    func testCodexDesktopSessionOpensExactThreadDeepLink() {
        let threadId = "019f8008-7c42-71f3-b479-13be677e97e4"
        var session = AgentSession(
            id: threadId,
            projectDir: "/Users/test/project",
            projectName: "project",
            agentSource: .codex,
            status: .active,
            eventCount: 1,
            startedAt: Date(),
            lastEventAt: Date()
        )
        session.rawSource = "codex-desktop"

        var openedURL: URL?
        IDETerminalFocus.focusSession(session) { url in
            openedURL = url
            return true
        }

        XCTAssertEqual(openedURL?.absoluteString, "codex://threads/\(threadId)")
    }
}
