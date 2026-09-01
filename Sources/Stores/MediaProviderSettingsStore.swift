import Foundation
import Observation

enum MediaProviderSettingsError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: t("creator.error.invalid_base_url")
        case .missingAPIKey: t("creator.error.missing_api_key")
        }
    }
}

@Observable
final class MediaProviderSettingsStore {
    static let customHTTPProviderID = "custom-http"

    var baseURL: String
    var imagePath: String
    var videoPath: String
    var imageModel: String
    var videoModel: String
    var apiKeyHeader: String
    var qworkBaseURL: String
    var qworkVideoModel: String
    var qworkAPIKeyHeader: String
    private(set) var hasAPIKey: Bool
    private(set) var hasQWorkAPIKey: Bool

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring
    private var qworkApprovedMaximumCostMicrocredits: Int64?

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        baseURL = defaults.string(forKey: "media_provider_base_url") ?? ""
        imagePath = defaults.string(forKey: "media_provider_image_path") ?? "v1/images/generations"
        videoPath = defaults.string(forKey: "media_provider_video_path") ?? "v1/videos/generations"
        imageModel = defaults.string(forKey: "media_provider_image_model") ?? ""
        videoModel = defaults.string(forKey: "media_provider_video_model") ?? ""
        apiKeyHeader = defaults.string(forKey: "media_provider_api_key_header") ?? "Authorization"
        qworkBaseURL = defaults.string(forKey: "qwork_media_base_url") ?? ""
        qworkVideoModel = defaults.string(forKey: "qwork_media_video_model") ?? ""
        qworkAPIKeyHeader = defaults.string(forKey: "qwork_media_api_key_header") ?? "Authorization"
        hasAPIKey = ((try? credentialStore.load(account: Self.customHTTPProviderID)) ?? nil) != nil
        hasQWorkAPIKey = ((try? credentialStore.load(account: QWorkSidecarMediaGenerationProvider.providerID)) ?? nil) != nil
    }

    func saveConfiguration(
        apiKey: String?,
        providerID: String = MediaProviderSettingsStore.customHTTPProviderID
    ) throws {
        let configuredBaseURL = providerID == QWorkSidecarMediaGenerationProvider.providerID
            ? qworkBaseURL
            : baseURL
        guard let url = URL(string: configuredBaseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MediaProviderSettingsError.invalidBaseURL
        }
        if providerID == QWorkSidecarMediaGenerationProvider.providerID {
            defaults.set(qworkBaseURL, forKey: "qwork_media_base_url")
            defaults.set(qworkVideoModel, forKey: "qwork_media_video_model")
            defaults.set(qworkAPIKeyHeader, forKey: "qwork_media_api_key_header")
        } else {
            defaults.set(baseURL, forKey: "media_provider_base_url")
            defaults.set(imagePath, forKey: "media_provider_image_path")
            defaults.set(videoPath, forKey: "media_provider_video_path")
            defaults.set(imageModel, forKey: "media_provider_image_model")
            defaults.set(videoModel, forKey: "media_provider_video_model")
            defaults.set(apiKeyHeader, forKey: "media_provider_api_key_header")
        }
        if let apiKey, !apiKey.isEmpty {
            try credentialStore.save(apiKey, account: providerID)
            if providerID == QWorkSidecarMediaGenerationProvider.providerID {
                hasQWorkAPIKey = true
            } else {
                hasAPIKey = true
            }
        }
    }

    func hasStoredAPIKey(for providerID: String) -> Bool {
        providerID == QWorkSidecarMediaGenerationProvider.providerID ? hasQWorkAPIKey : hasAPIKey
    }

    func makeProvider(id: String) throws -> any MediaGenerationProvider {
        if id == MockMediaGenerationProvider.providerID {
            return MockMediaGenerationProvider()
        }
        let configuredBaseURL = id == QWorkSidecarMediaGenerationProvider.providerID
            ? qworkBaseURL
            : baseURL
        guard let url = URL(string: configuredBaseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MediaProviderSettingsError.invalidBaseURL
        }
        guard id == Self.customHTTPProviderID || id == QWorkSidecarMediaGenerationProvider.providerID else {
            throw MediaProviderSettingsError.invalidBaseURL
        }
        guard let key = try credentialStore.load(account: id), !key.isEmpty else {
            throw MediaProviderSettingsError.missingAPIKey
        }
        if id == QWorkSidecarMediaGenerationProvider.providerID {
            return QWorkSidecarMediaGenerationProvider(client: QWorkSidecarMediaClient(
                configuration: QWorkSidecarMediaConfiguration(
                    baseURL: url,
                    videoModel: qworkVideoModel,
                    apiKeyHeader: qworkAPIKeyHeader
                ),
                apiKey: key,
                approvedMaximumCostMicrocredits: qworkApprovedMaximumCostMicrocredits
            ))
        }
        return HTTPMediaGenerationProvider(
            configuration: HTTPMediaProviderConfiguration(
                id: Self.customHTTPProviderID,
                displayName: "Custom API / MCP Bridge",
                baseURL: url,
                imagePath: imagePath,
                videoPath: videoPath,
                imageModel: imageModel,
                videoModel: videoModel,
                apiKeyHeader: apiKeyHeader
            ),
            apiKey: key
        )
    }

    func quoteQWorkImageToVideo() async throws -> QWorkMediaQuote {
        guard let provider = try makeProvider(id: QWorkSidecarMediaGenerationProvider.providerID)
            as? QWorkSidecarMediaGenerationProvider else {
            throw MediaProviderSettingsError.invalidBaseURL
        }
        return try await provider.client.quoteImageToVideo()
    }

    func approveQWorkQuote(_ quote: QWorkMediaQuote) {
        qworkApprovedMaximumCostMicrocredits = quote.maximumCostMicrocredits
    }

    func clearQWorkCostApproval() {
        qworkApprovedMaximumCostMicrocredits = nil
    }
}
