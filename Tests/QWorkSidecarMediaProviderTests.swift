import Foundation
import XCTest
@testable import PeachyPet

final class QWorkSidecarMediaProviderTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testAnchorKeepsTheCharacterReferenceWithoutCallingUnsupportedImageGeneration() async throws {
        let reference = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwork-anchor-\(UUID().uuidString).png")
        let expected = Data("reference-image".utf8)
        try expected.write(to: reference)
        defer { try? FileManager.default.removeItem(at: reference) }

        StubURLProtocol.handler = { request in
            XCTFail("Anchor passthrough must not call QWork: \(request.url?.absoluteString ?? "")")
            return Self.response(for: request, status: 500, data: Data())
        }
        let provider = makeProvider()
        let media = try await provider.generateAnchor(request: AnchorGenerationRequest(
            project: .make(name: "Peach", stylePrompt: "soft", states: [.idle]),
            state: MascotProject.make(name: "Peach", stylePrompt: "soft", states: [.idle]).states[0],
            referenceURL: reference,
            styleReferenceURL: nil
        ))

        XCTAssertEqual(media.data, expected)
        XCTAssertEqual(media.fileExtension, "png")
    }

    func testQuoteThenCreatePollAndDownloadVideoUsingQWorkSidecarContract() async throws {
        let anchor = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwork-loop-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: anchor)
        defer { try? FileManager.default.removeItem(at: anchor) }

        var requestedPaths: [String] = []
        var createBody: [String: Any] = [:]
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            switch (request.httpMethod, path) {
            case ("POST", "/api/v1/sidecar/media/quotes"):
                return Self.jsonResponse(for: request, status: 200, object: [
                    "kind": "video",
                    "operation": "image_to_video",
                    "model": "klingai/kling-v3",
                    "normalizedParameters": [:],
                    "estimatedCostMicrocredits": 50_000,
                    "maximumCostMicrocredits": 50_000,
                    "exact": true,
                    "pricingVersion": "media-v1",
                    "expiresAt": "2026-09-01T12:00:00Z",
                ])
            case ("POST", "/api/v1/sidecar/media/videos"):
                createBody = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: try Self.bodyData(request)) as? [String: Any]
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sidecar-token")
                XCTAssertFalse((request.value(forHTTPHeaderField: "Idempotency-Key") ?? "").isEmpty)
                return Self.jsonResponse(for: request, status: 201, object: [
                    "id": "task-1",
                    "kind": "video",
                    "model": "klingai/kling-v3",
                    "status": "queued",
                    "estimatedCostMicrocredits": 50_000,
                    "chargedCostMicrocredits": 0,
                    "createdAt": "2026-09-01T12:00:00Z",
                    "updatedAt": "2026-09-01T12:00:00Z",
                ])
            case ("GET", "/api/v1/sidecar/media/tasks/task-1"):
                return Self.jsonResponse(for: request, status: 200, object: [
                    "id": "task-1",
                    "kind": "video",
                    "model": "klingai/kling-v3",
                    "status": "succeeded",
                    "results": [[
                        "index": 0,
                        "downloadPath": "/api/v1/sidecar/media/tasks/task-1/results/0",
                        "mediaType": "video/mp4",
                    ]],
                    "estimatedCostMicrocredits": 50_000,
                    "chargedCostMicrocredits": 50_000,
                    "createdAt": "2026-09-01T12:00:00Z",
                    "updatedAt": "2026-09-01T12:00:01Z",
                ])
            case ("GET", "/api/v1/sidecar/media/tasks/task-1/results/0"):
                return Self.response(
                    for: request,
                    status: 200,
                    data: Data("video-bytes".utf8),
                    headers: ["Content-Type": "video/mp4"]
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                return Self.response(for: request, status: 404, data: Data())
            }
        }

        let provider = makeProvider()
        let project = MascotProject.make(name: "Peach", stylePrompt: "soft 3D", states: [.idle])
        let media = try await provider.generateLoop(request: LoopGenerationRequest(
            project: project,
            state: project.states[0],
            anchorURL: anchor
        ))

        XCTAssertEqual(
            requestedPaths,
            [
                "/api/v1/sidecar/media/quotes",
                "/api/v1/sidecar/media/videos",
                "/api/v1/sidecar/media/tasks/task-1",
                "/api/v1/sidecar/media/tasks/task-1/results/0",
            ]
        )
        XCTAssertEqual(createBody["model"] as? String, "klingai/kling-v3")
        XCTAssertEqual(createBody["duration"] as? Int, 5)
        let content = try XCTUnwrap(createBody["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertTrue((content[1]["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(media.data, Data("video-bytes".utf8))
        XCTAssertEqual(media.fileExtension, "mp4")
    }

    func testQuoteReturnsExactMaximumCostForPreGenerationConfirmation() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sidecar/media/quotes")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sidecar-token")
            return Self.jsonResponse(for: request, status: 200, object: [
                "kind": "video",
                "operation": "image_to_video",
                "model": "klingai/kling-v3",
                "normalizedParameters": ["duration": 5],
                "estimatedCostMicrocredits": 50_000,
                "maximumCostMicrocredits": 50_000,
                "exact": true,
                "pricingVersion": "media-v1",
                "expiresAt": "2026-09-01T12:00:00Z",
            ])
        }

        let quote = try await makeClient().quoteImageToVideo()

        XCTAssertTrue(quote.exact)
        XCTAssertEqual(quote.maximumCostMicrocredits, 50_000)
        XCTAssertEqual(quote.operation, "image_to_video")
    }

    func testSettingsKeepQWorkCredentialSeparateAndBuildQWorkProvider() throws {
        let suite = "QWorkSidecarMediaProviderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentialStore()
        let settings = MediaProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        settings.baseURL = "https://custom.example/v1"
        settings.videoModel = "custom-video"
        settings.qworkBaseURL = "https://qwork.example/api/v1"
        settings.qworkVideoModel = "klingai/kling-v3"
        settings.qworkAPIKeyHeader = "Authorization"

        try settings.saveConfiguration(
            apiKey: "Bearer sidecar-token",
            providerID: QWorkSidecarMediaGenerationProvider.providerID
        )
        let provider = try settings.makeProvider(id: QWorkSidecarMediaGenerationProvider.providerID)

        XCTAssertTrue(provider is QWorkSidecarMediaGenerationProvider)
        XCTAssertTrue(settings.hasStoredAPIKey(for: QWorkSidecarMediaGenerationProvider.providerID))
        XCTAssertNil(try credentials.load(account: MediaProviderSettingsStore.customHTTPProviderID))
        XCTAssertEqual(settings.baseURL, "https://custom.example/v1")
        XCTAssertEqual(settings.videoModel, "custom-video")

        let reloaded = MediaProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        XCTAssertEqual(reloaded.qworkBaseURL, "https://qwork.example/api/v1")
        XCTAssertEqual(reloaded.qworkVideoModel, "klingai/kling-v3")
    }

    func testInexactQuoteStopsBeforeCreatingPaidTask() async throws {
        var requestedPaths: [String] = []
        StubURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            return Self.jsonResponse(for: request, status: 200, object: [
                "operation": "image_to_video",
                "estimatedCostMicrocredits": 50_000,
                "maximumCostMicrocredits": 50_000,
                "exact": false,
                "pricingVersion": "media-v1",
            ])
        }

        do {
            _ = try await makeClient().generateVideo(
                prompt: "idle loop",
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                imageMIMEType: "image/png"
            )
            XCTFail("Expected an inexact quote to stop generation")
        } catch QWorkSidecarMediaError.inexactQuote {
            XCTAssertEqual(requestedPaths, ["/api/v1/sidecar/media/quotes"])
        }
    }

    func testMissingCostApprovalStopsBeforeCreatingPaidTask() async throws {
        var requestedPaths: [String] = []
        StubURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            return Self.jsonResponse(for: request, status: 200, object: [
                "operation": "image_to_video",
                "estimatedCostMicrocredits": 50_000,
                "maximumCostMicrocredits": 50_000,
                "exact": true,
                "pricingVersion": "media-v1",
            ])
        }

        do {
            _ = try await makeClient(approvedMaximumCostMicrocredits: nil).generateVideo(
                prompt: "idle loop",
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                imageMIMEType: "image/png"
            )
            XCTFail("Expected missing approval to stop generation")
        } catch QWorkSidecarMediaError.missingCostApproval {
            XCTAssertEqual(requestedPaths, ["/api/v1/sidecar/media/quotes"])
        }
    }

    func testPriceIncreaseAboveApprovedMaximumStopsBeforeCreatingPaidTask() async throws {
        var requestedPaths: [String] = []
        StubURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            return Self.jsonResponse(for: request, status: 200, object: [
                "operation": "image_to_video",
                "estimatedCostMicrocredits": 60_000,
                "maximumCostMicrocredits": 60_000,
                "exact": true,
                "pricingVersion": "media-v2",
            ])
        }

        do {
            _ = try await makeClient(approvedMaximumCostMicrocredits: 50_000).generateVideo(
                prompt: "idle loop",
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                imageMIMEType: "image/png"
            )
            XCTFail("Expected price increase to stop generation")
        } catch QWorkSidecarMediaError.quoteExceedsApproval {
            XCTAssertEqual(requestedPaths, ["/api/v1/sidecar/media/quotes"])
        }
    }

    func testFailedTaskStopsBeforeDownloadingResult() async throws {
        var requestedPaths: [String] = []
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            switch (request.httpMethod, path) {
            case ("POST", "/api/v1/sidecar/media/quotes"):
                return Self.jsonResponse(for: request, status: 200, object: [
                    "operation": "image_to_video",
                    "estimatedCostMicrocredits": 50_000,
                    "maximumCostMicrocredits": 50_000,
                    "exact": true,
                    "pricingVersion": "media-v1",
                ])
            case ("POST", "/api/v1/sidecar/media/videos"):
                return Self.jsonResponse(for: request, status: 201, object: [
                    "id": "task-failed",
                    "status": "failed",
                    "failureCode": "UPSTREAM_REJECTED",
                ])
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                return Self.response(for: request, status: 404, data: Data())
            }
        }

        do {
            _ = try await makeClient().generateVideo(
                prompt: "idle loop",
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                imageMIMEType: "image/png"
            )
            XCTFail("Expected task failure")
        } catch QWorkSidecarMediaError.taskFailed(let code) {
            XCTAssertEqual(code, "UPSTREAM_REJECTED")
            XCTAssertEqual(
                requestedPaths,
                ["/api/v1/sidecar/media/quotes", "/api/v1/sidecar/media/videos"]
            )
        }
    }

    func testCrossOriginDownloadPathIsRejectedWithoutLeakingAuthentication() async throws {
        var requestedHosts: [String] = []
        StubURLProtocol.handler = { request in
            requestedHosts.append(request.url?.host ?? "")
            switch (request.httpMethod, request.url?.path ?? "") {
            case ("POST", "/api/v1/sidecar/media/quotes"):
                return Self.jsonResponse(for: request, status: 200, object: [
                    "operation": "image_to_video",
                    "estimatedCostMicrocredits": 50_000,
                    "maximumCostMicrocredits": 50_000,
                    "exact": true,
                    "pricingVersion": "media-v1",
                ])
            case ("POST", "/api/v1/sidecar/media/videos"):
                return Self.jsonResponse(for: request, status: 201, object: [
                    "id": "task-complete",
                    "status": "succeeded",
                    "results": [["downloadPath": "https://untrusted.example/video.mp4"]],
                ])
            default:
                XCTFail("The client must reject a cross-origin result before requesting it")
                return Self.response(for: request, status: 500, data: Data())
            }
        }

        do {
            _ = try await makeClient().generateVideo(
                prompt: "idle loop",
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                imageMIMEType: "image/png"
            )
            XCTFail("Expected cross-origin download rejection")
        } catch QWorkSidecarMediaError.invalidResponse {
            XCTAssertEqual(requestedHosts, ["qwork.example", "qwork.example"])
        }
    }

    func testQuoteSummaryCountsStateLoopsAndIdleHubTransitions() {
        let quote = QWorkMediaQuote(
            operation: "image_to_video",
            estimatedCostMicrocredits: 50_000,
            maximumCostMicrocredits: 50_000,
            exact: true,
            pricingVersion: "media-v1"
        )

        let summary = QWorkGenerationQuoteSummary(quote: quote, stateCount: 3)

        XCTAssertEqual(summary.videoTaskCount, 7)
        XCTAssertEqual(summary.maximumTotalMicrocredits, 350_000)
        XCTAssertEqual(summary.maximumUnitCredits, 5)
        XCTAssertEqual(summary.maximumTotalCredits, 35)
    }

    private func makeProvider() -> QWorkSidecarMediaGenerationProvider {
        QWorkSidecarMediaGenerationProvider(client: makeClient())
    }

    private func makeClient(
        approvedMaximumCostMicrocredits: Int64? = 50_000
    ) -> QWorkSidecarMediaClient {
        QWorkSidecarMediaClient(
            configuration: QWorkSidecarMediaConfiguration(
                baseURL: URL(string: "https://qwork.example/api/v1")!,
                videoModel: "klingai/kling-v3",
                apiKeyHeader: "Authorization",
                fixedDurationSeconds: 5,
                pollLimit: 2
            ),
            apiKey: "Bearer sidecar-token",
            approvedMaximumCostMicrocredits: approvedMaximumCostMicrocredits,
            session: makeSession(),
            waitBeforePolling: {}
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonResponse(
        for request: URLRequest,
        status: Int,
        object: Any
    ) -> (HTTPURLResponse, Data) {
        response(
            for: request,
            status: status,
            data: try! JSONSerialization.data(withJSONObject: object),
            headers: ["Content-Type": "application/json"]
        )
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else {
            throw URLError(.cannotDecodeRawData)
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        data: Data,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!,
            data
        )
    }
}

private final class MemoryCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]

    func save(_ secret: String, account: String) throws { values[account] = secret }
    func load(account: String) throws -> String? { values[account] }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
