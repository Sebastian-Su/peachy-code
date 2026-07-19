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
        XCTAssertFalse(transport.capabilities.contains(.textInput))
        XCTAssertFalse(transport.capabilities.contains(.updatedPermissions))
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

    func testSendDecisionWritesWellFormedHTTPToConnection() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)

        var receivedData = Data()
        let dataExpectation = XCTestExpectation(description: "Data received and connection closed")
        let listenerReadyExpectation = XCTestExpectation(description: "Listener ready")

        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerReadyExpectation.fulfill()
            }
        }

        listener.newConnectionHandler = { serverConn in
            serverConn.start(queue: .global())

            func receiveMore() {
                serverConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        receivedData.append(data)
                    }
                    if isComplete || error != nil {
                        dataExpectation.fulfill()
                    } else {
                        receiveMore()
                    }
                }
            }
            receiveMore()
        }

        listener.start(queue: .global())
        await fulfillment(of: [listenerReadyExpectation], timeout: 5)

        guard let port = listener.port else {
            XCTFail("Listener port not assigned after ready state")
            listener.cancel()
            return
        }

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let transport = CodexHookTransport(connection: connection)
        let connReadyExpectation = XCTestExpectation(description: "Connection ready")

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connReadyExpectation.fulfill()
            }
        }
        connection.start(queue: .global())

        await fulfillment(of: [connReadyExpectation], timeout: 5)

        transport.sendDecision(.deny)

        await fulfillment(of: [dataExpectation], timeout: 5)

        // After fulfillment, all NWConnection callbacks have completed writing to receivedData.
        // Safe to read without locking here.
        let received = receivedData
        let receivedString = String(data: received, encoding: .utf8) ?? ""
        XCTAssertTrue(
            receivedString.hasPrefix("HTTP/1.1 403 Forbidden\r\n"),
            "Expected HTTP/1.1 403 Forbidden prefix, got: \(String(receivedString.prefix(80)))"
        )
        XCTAssertTrue(
            receivedString.contains("X-Exit-Code: 2"),
            "Expected X-Exit-Code: 2 header in response"
        )
        XCTAssertTrue(
            receivedString.contains("\r\n\r\n"),
            "Expected CRLF header/body separator in response"
        )
        XCTAssertTrue(
            receivedString.contains("\"behavior\":\"deny\""),
            "Expected deny behavior JSON in response body"
        )

        listener.cancel()
        connection.cancel()
    }
}
