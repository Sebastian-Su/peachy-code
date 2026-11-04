import XCTest
@testable import PeachyPet

final class SecretRedactorTests: XCTestCase {
    func testRedactsAuthorizationHeaderAndBearerValues() {
        XCTAssertEqual(
            SecretRedactor.redact(#"curl https://api.example.com -H "Authorization: Bearer sk-abc123.DEF_456" -d x"#),
            #"curl https://api.example.com -H "Authorization: Bearer <redacted>" -d x"#
        )
        XCTAssertEqual(SecretRedactor.redact("authorization=Basic dXNlcjpwYXNz"), "authorization=Basic <redacted>")
        XCTAssertEqual(SecretRedactor.redact("token is Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig"), "token is Bearer <redacted>")
        XCTAssertEqual(SecretRedactor.redact(#"{"Authorization":"tok_live_9999"}"#), #"{"Authorization":"<redacted>"}"#)
    }

    func testLeavesOrdinaryTextAlone() {
        for text in ["grep -c Authorization file.txt", "the Bearer of bad news", "Authorization: Bearer <redacted>", "echo hi"] {
            XCTAssertEqual(SecretRedactor.redact(text), text)
        }
    }

    /// Everything LocalStorage writes is redacted, and the file still decodes (N1, N6).
    func testSavedRecordsAreRedactedAndStillLoad() throws {
        let filename = "redactor-test-\(UUID().uuidString).json"
        let record = ApprovalRecord(
            id: UUID(), toolName: "Bash",
            toolInputSummary: #"curl -H "Authorization: Bearer sk-secret-value" https://api.example.com"#,
            projectName: "p", assistantName: "Codex", outcome: .allowed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.25), resolvedAt: Date(), sessionId: "s"
        )
        LocalStorage.save([record], to: filename)
        defer { try? FileManager.default.removeItem(at: LocalStorage.appSupportDir.appendingPathComponent(filename)) }

        let raw = try String(contentsOf: LocalStorage.appSupportDir.appendingPathComponent(filename), encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-secret-value"))
        let loaded = try XCTUnwrap(LocalStorage.load([ApprovalRecord].self, from: filename))
        XCTAssertEqual(loaded.first?.toolInputSummary, #"curl -H "Authorization: Bearer <redacted>" https://api.example.com"#)
        XCTAssertEqual(loaded.first?.createdAt, record.createdAt)
    }
}
