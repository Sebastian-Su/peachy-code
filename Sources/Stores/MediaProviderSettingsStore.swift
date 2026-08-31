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
    private(set) var hasAPIKey: Bool

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring

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
        hasAPIKey = ((try? credentialStore.load(account: Self.customHTTPProviderID)) ?? nil) != nil
    }

    func saveConfiguration(apiKey: String?) throws {
        guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MediaProviderSettingsError.invalidBaseURL
        }
        defaults.set(baseURL, forKey: "media_provider_base_url")
        defaults.set(imagePath, forKey: "media_provider_image_path")
        defaults.set(videoPath, forKey: "media_provider_video_path")
        defaults.set(imageModel, forKey: "media_provider_image_model")
        defaults.set(videoModel, forKey: "media_provider_video_model")
        defaults.set(apiKeyHeader, forKey: "media_provider_api_key_header")
        if let apiKey, !apiKey.isEmpty {
            try credentialStore.save(apiKey, account: Self.customHTTPProviderID)
            hasAPIKey = true
        }
    }

    func makeProvider(id: String) throws -> any MediaGenerationProvider {
        if id == MockMediaGenerationProvider.providerID {
            return MockMediaGenerationProvider()
        }
        guard id == Self.customHTTPProviderID,
              let url = URL(string: baseURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MediaProviderSettingsError.invalidBaseURL
        }
        guard let key = try credentialStore.load(account: Self.customHTTPProviderID), !key.isEmpty else {
            throw MediaProviderSettingsError.missingAPIKey
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
}
