import XCTest
@testable import PeachyPet

final class SessionRouteTests: XCTestCase {
    private func session(host: SessionHost, engine: AgentSource = .codex, terminalBundleId: String? = nil) -> AgentSession {
        var s = AgentSession(id: "route-\(UUID().uuidString)", projectDir: "/tmp/p", projectName: "p",
                             agentSource: engine, status: .active, eventCount: 1, startedAt: Date(), lastEventAt: Date())
        s.host = host
        s.terminalBundleId = terminalBundleId
        return s
    }

    /// The app drawn at the end of the route is the app the jump button opens.
    func testRouteDestinationMatchesWhereJumpGoes() {
        let paseo = SessionRoute(session: session(host: .paseo(agentId: "a1")))
        XCTAssertEqual(paseo.destinationBundleId, PaseoRegistry.bundleId)
        XCTAssertEqual(paseo.destination, .paseo)
        XCTAssertTrue(paseo.canJump)

        let desktop = SessionRoute(session: session(host: .codexDesktop))
        XCTAssertEqual(desktop.destinationBundleId, "com.openai.codex")
        XCTAssertTrue(desktop.canJump)

        let terminal = SessionRoute(session: session(host: .terminal, engine: .claudeCode, terminalBundleId: "com.mitchellh.ghostty"))
        XCTAssertEqual(terminal.destinationBundleId, "com.mitchellh.ghostty")
        XCTAssertEqual(terminal.engine, .claudeCode)
        XCTAssertTrue(terminal.canJump)
    }

    func testOtherHostCannotJump() {
        let route = SessionRoute(session: session(host: .other(originator: "baocut")))
        XCTAssertFalse(route.canJump)
        XCTAssertEqual(route.destination, .other("baocut"))
        XCTAssertNil(route.destinationBundleId)
    }

    func testOtherHostJumpDoesNothing() {
        var opened: [URL] = []
        IDETerminalFocus.focusSession(session(host: .other(originator: "baocut")), urlOpener: { opened.append($0); return true })
        XCTAssertTrue(opened.isEmpty)
    }
}
