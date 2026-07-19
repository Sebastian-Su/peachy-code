import XCTest
import Network
@testable import peachy_code

final class CodexHookTransportTests: XCTestCase {
    func testCapabilitiesOnlyPermissionResponse() {
        let conn = NWConnection(host: "localhost", port: 1, using: .tcp)
        let transport = CodexHookTransport(connection: conn)
        XCTAssertEqual(transport.capabilities, [.permissionResponse])
        XCTAssertFalse(transport.capabilities.contains(.openTerminal))
        XCTAssertFalse(transport.capabilities.contains(.updatedInput))
        conn.cancel()
    }

    func testDenyHttpResponseFormatMatchesCodexContract() {
        // 验证 deny 的回写格式与 Codex PermissionRequest 契约一致
        let (status, body, exit) = PermissionDecision.deny.httpResponse
        XCTAssertEqual(status, "403 Forbidden")
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(body.contains("\"hookEventName\":\"PermissionRequest\""))
        XCTAssertTrue(body.contains("\"decision\":{\"behavior\":\"deny\"}"))
    }

    func testAllowHttpResponseFormat() {
        let (status, body, exit) = PermissionDecision.allow.httpResponse
        XCTAssertEqual(status, "200 OK")
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(body.contains("\"decision\":{\"behavior\":\"allow\"}"))
    }
}
