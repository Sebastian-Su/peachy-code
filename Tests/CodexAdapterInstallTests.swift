import XCTest
@testable import PeachyPet

final class CodexAdapterInstallTests: XCTestCase {
    // assistantClientKind 是分发依据 — 固化其对 codex-cli / claude 的判定
    func testAssistantClientKindClassifiesCodexCLI() {
        let e = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1",
                           cwd: nil, source: "codex-cli")
        XCTAssertEqual(e.assistantClientKind, .codexCLI)
    }

    func testAssistantClientKindClassifiesClaude() {
        let e = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s1",
                           cwd: nil, source: "startup")
        XCTAssertEqual(e.assistantClientKind, .claude)
    }

    func testCodexEventIsRoutedToCodexTransportKind() {
        // 分发判据：非 .claude 即用 CodexHookTransport
        let codex = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s", cwd: nil, source: "codex-cli")
        let claude = AgentEvent(hookEventName: "PermissionRequest", sessionId: "s", cwd: nil, source: "startup")
        XCTAssertTrue(codex.assistantClientKind != .claude)
        XCTAssertTrue(claude.assistantClientKind == .claude)
    }
}
