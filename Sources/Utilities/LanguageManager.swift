import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case en = "en"
    case zh = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        }
    }
}

@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private(set) var language: AppLanguage = .en
    private(set) var bundle: Bundle = .main
    /// Source bundle to look up .lproj directories from. Defaults to Bundle.main;
    /// tests can override via setSourceBundle(_:) to use Bundle.module.
    private var sourceBundle: Bundle = .main

    private init() {
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let lang = AppLanguage(rawValue: stored) ?? .en
        setLanguage(lang)
    }

    /// For testing only — override the bundle used to locate .lproj resources.
    func setSourceBundle(_ src: Bundle) {
        sourceBundle = src
        setLanguage(language)
    }

    func setLanguage(_ lang: AppLanguage) {
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage")
        // SPM packages their processed resources into a sub-bundle named
        // <TargetName>_<TargetName>.bundle inside the app's Resources directory.
        // We must search there first, then fall back to the source bundle directly.
        let candidates: [Bundle] = [
            Bundle(path: sourceBundle.bundlePath + "/PeachyPet_PeachyPet.bundle"),
            Bundle(path: sourceBundle.resourcePath.map { $0 + "/PeachyPet_PeachyPet.bundle" } ?? ""),
        ].compactMap { $0 } + [sourceBundle]

        for candidate in candidates {
            if let path = candidate.path(forResource: lang.rawValue, ofType: "lproj"),
               let langBundle = Bundle(path: path) {
                bundle = langBundle
                return
            }
        }
        bundle = sourceBundle
    }
}

func t(_ key: String) -> String {
    LanguageManager.shared.bundle.localizedString(forKey: key, value: key, table: nil)
}
