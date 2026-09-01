import Foundation

struct QWorkSidecarMediaConfiguration: Equatable {
    var baseURL: URL
    var videoModel: String
    var apiKeyHeader: String
    var fixedDurationSeconds: Int = 5
    var pollLimit: Int = 300
}

struct QWorkMediaQuote: Decodable, Equatable {
    let operation: String
    let estimatedCostMicrocredits: Int64
    let maximumCostMicrocredits: Int64
    let exact: Bool
    let pricingVersion: String
}

struct QWorkGenerationQuoteSummary: Equatable {
    let quote: QWorkMediaQuote
    let videoTaskCount: Int

    init(quote: QWorkMediaQuote, stateCount: Int) {
        self.quote = quote
        let normalizedStateCount = max(1, stateCount)
        videoTaskCount = normalizedStateCount + 2 * (normalizedStateCount - 1)
    }

    init(quote: QWorkMediaQuote, videoTaskCount: Int) {
        self.quote = quote
        self.videoTaskCount = max(0, videoTaskCount)
    }

    var maximumTotalMicrocredits: Int64 {
        quote.maximumCostMicrocredits * Int64(videoTaskCount)
    }
}

enum QWorkSidecarMediaError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case inexactQuote
    case missingCostApproval
    case quoteExceedsApproval
    case taskFailed(String?)
    case taskTimedOut
    case missingResult

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            t("creator.error.qwork_invalid_response")
        case .requestFailed(let status):
            String(format: t("creator.error.provider_http"), status)
        case .inexactQuote:
            t("creator.error.qwork_inexact_quote")
        case .missingCostApproval:
            t("creator.error.qwork_missing_cost_approval")
        case .quoteExceedsApproval:
            t("creator.error.qwork_quote_exceeds_approval")
        case .taskFailed(let code):
            String(format: t("creator.error.qwork_task_failed"), code ?? "unknown")
        case .taskTimedOut:
            t("creator.error.qwork_task_timeout")
        case .missingResult:
            t("creator.error.qwork_missing_result")
        }
    }
}

final class QWorkSidecarMediaClient {
    private let configuration: QWorkSidecarMediaConfiguration
    private let apiKey: String
    private let approvedMaximumCostMicrocredits: Int64?
    private let session: URLSession
    private let waitBeforePolling: () async throws -> Void

    init(
        configuration: QWorkSidecarMediaConfiguration,
        apiKey: String,
        approvedMaximumCostMicrocredits: Int64? = nil,
        session: URLSession = .shared,
        waitBeforePolling: @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(1))
        }
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.approvedMaximumCostMicrocredits = approvedMaximumCostMicrocredits
        self.session = session
        self.waitBeforePolling = waitBeforePolling
    }

    func quoteImageToVideo() async throws -> QWorkMediaQuote {
        let response: QWorkMediaQuote = try await postJSON(
            path: "sidecar/media/quotes",
            body: [
                "kind": "video",
                "model": configuration.videoModel,
                "duration": configuration.fixedDurationSeconds,
                "contentTypes": ["text", "image_url"],
                "extraBody": videoExtraBody,
            ]
        )
        guard response.exact, response.operation == "image_to_video" else {
            throw QWorkSidecarMediaError.inexactQuote
        }
        return response
    }

    func generateVideo(prompt: String, imageData: Data, imageMIMEType: String) async throws -> GeneratedMedia {
        let quote = try await quoteImageToVideo()
        guard let approvedMaximumCostMicrocredits else {
            throw QWorkSidecarMediaError.missingCostApproval
        }
        guard quote.maximumCostMicrocredits <= approvedMaximumCostMicrocredits else {
            throw QWorkSidecarMediaError.quoteExceedsApproval
        }
        let body: [String: Any] = [
            "model": configuration.videoModel,
            "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "url": "data:\(imageMIMEType);base64,\(imageData.base64EncodedString())"],
            ],
            "duration": configuration.fixedDurationSeconds,
            "extraBody": videoExtraBody,
        ]
        var task: QWorkMediaTask = try await postJSON(
            path: "sidecar/media/videos",
            body: body,
            headers: ["Idempotency-Key": UUID().uuidString]
        )

        for _ in 0..<max(1, configuration.pollLimit) {
            switch task.status {
            case "succeeded":
                return try await download(task: task)
            case "failed":
                throw QWorkSidecarMediaError.taskFailed(task.failureCode)
            case "queued", "running":
                try await waitBeforePolling()
                task = try await getJSON(path: "sidecar/media/tasks/\(task.id)")
            default:
                throw QWorkSidecarMediaError.invalidResponse
            }
        }
        throw QWorkSidecarMediaError.taskTimedOut
    }

    private var videoExtraBody: [String: Any] {
        ["aspect_ratio": "1:1", "mode": "std", "sound": "off"]
    }

    private func download(task: QWorkMediaTask) async throws -> GeneratedMedia {
        guard let result = task.results?.first else {
            throw QWorkSidecarMediaError.missingResult
        }
        let url = try resolvedURL(path: result.downloadPath)
        guard isSameOrigin(url, as: configuration.baseURL) else {
            throw QWorkSidecarMediaError.invalidResponse
        }
        var request = URLRequest(url: url)
        applyAuthentication(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QWorkSidecarMediaError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw QWorkSidecarMediaError.requestFailed(http.statusCode)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        return GeneratedMedia(
            data: data,
            fileExtension: mediaExtension(contentType: contentType, url: url),
            mediaType: .video
        )
    }

    private func postJSON<Response: Decodable>(
        path: String,
        body: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: try resolvedURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyAuthentication(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decodedResponse(for: request)
    }

    private func getJSON<Response: Decodable>(path: String) async throws -> Response {
        var request = URLRequest(url: try resolvedURL(path: path))
        applyAuthentication(to: &request)
        return try await decodedResponse(for: request)
    }

    private func decodedResponse<Response: Decodable>(for request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QWorkSidecarMediaError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QWorkSidecarMediaError.requestFailed(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw QWorkSidecarMediaError.invalidResponse
        }
    }

    private func applyAuthentication(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: configuration.apiKeyHeader)
    }

    private func resolvedURL(path: String) throws -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        guard let url = URL(string: path, relativeTo: configuration.baseURL.appendingPathComponent("/"))?.absoluteURL else {
            throw QWorkSidecarMediaError.invalidResponse
        }
        return url
    }

    private func mediaExtension(contentType: String?, url: URL) -> String {
        switch contentType?.lowercased() {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        default: url.pathExtension.isEmpty ? "bin" : url.pathExtension
        }
    }

    private func isSameOrigin(_ candidate: URL, as baseURL: URL) -> Bool {
        candidate.scheme?.lowercased() == baseURL.scheme?.lowercased() &&
            candidate.host?.lowercased() == baseURL.host?.lowercased() &&
            effectivePort(candidate) == effectivePort(baseURL)
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

struct QWorkSidecarMediaGenerationProvider: MediaGenerationProvider {
    static let providerID = "qwork-sidecar"
    let id = providerID
    let displayName = "QWork Sidecar"
    let client: QWorkSidecarMediaClient

    func generateAnchor(request: AnchorGenerationRequest) async throws -> GeneratedMedia {
        let data = try Data(contentsOf: request.referenceURL)
        let fileExtension = request.referenceURL.pathExtension.isEmpty
            ? "png"
            : request.referenceURL.pathExtension
        return GeneratedMedia(data: data, fileExtension: fileExtension, mediaType: .image)
    }

    func generateLoop(request: LoopGenerationRequest) async throws -> GeneratedMedia {
        try await client.generateVideo(
            prompt: combinedPrompt(
                project: request.project,
                motionPrompt: request.state.prompt + ", return to the supplied character pose"
            ),
            imageData: Data(contentsOf: request.anchorURL),
            imageMIMEType: imageMIMEType(url: request.anchorURL)
        )
    }

    func generateTransition(request: TransitionGenerationRequest) async throws -> GeneratedMedia {
        try await client.generateVideo(
            prompt: combinedPrompt(project: request.project, motionPrompt: request.transition.prompt),
            imageData: Data(contentsOf: request.sourceAnchorURL),
            imageMIMEType: imageMIMEType(url: request.sourceAnchorURL)
        )
    }

    private func combinedPrompt(project: MascotProject, motionPrompt: String) -> String {
        [project.stylePrompt, motionPrompt, "flat removable background, preserve character identity"]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private func imageMIMEType(url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: "image/png"
        }
    }
}

private struct QWorkMediaTask: Decodable {
    let id: String
    let status: String
    let failureCode: String?
    let results: [QWorkMediaResult]?
}

private struct QWorkMediaResult: Decodable {
    let downloadPath: String
}
