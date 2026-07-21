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
    /// Cached strings dictionary for the current language (used when Bundle lookup fails)
    private var stringsCache: [String: String] = [:]
    /// Candidate root directories to search for .lproj subdirectories
    private var searchRoots: [String] = []

    private init() {
        searchRoots = Self.buildSearchRoots(from: .main)
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let lang = AppLanguage(rawValue: stored) ?? .en
        setLanguage(lang)
    }

    /// For testing — override the root path containing .lproj directories.
    func setSourceBundle(_ src: Bundle) {
        searchRoots = Self.buildSearchRoots(from: src)
        setLanguage(language)
    }

    /// For testing — set the root directory path that contains .lproj directories directly.
    func setResourceRootPath(_ path: String) {
        searchRoots = [
            (path as NSString).appendingPathComponent("PeachyPet_PeachyPet.bundle"),
            path,
        ]
        setLanguage(language)
    }

    private static func buildSearchRoots(from b: Bundle) -> [String] {
        var roots: [String] = []
        // Sub-bundle produced by SPM .process() for the PeachyPet target
        let subBundleName = "PeachyPet_PeachyPet.bundle"
        if let rp = b.resourcePath {
            roots.append((rp as NSString).appendingPathComponent(subBundleName))
            roots.append(rp)
        }
        roots.append((b.bundlePath as NSString).appendingPathComponent(subBundleName))
        roots.append(b.bundlePath)
        return roots
    }

    func setLanguage(_ lang: AppLanguage) {
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "appLanguage")
        stringsCache = [:]

        // Try to find a Bundle wrapping the .lproj, then fall back to direct file read
        for root in searchRoots {
            let lprojDir = (root as NSString).appendingPathComponent("\(lang.rawValue).lproj")
            let stringsFile = (lprojDir as NSString).appendingPathComponent("Localizable.strings")
            guard FileManager.default.fileExists(atPath: stringsFile) else { continue }

            // Load strings directly — works for both text and binary .strings format
            if let dict = loadStrings(at: stringsFile) {
                stringsCache = dict
                PeachyLog.lang.info("Language set to \(lang.rawValue): loaded \(dict.count) keys from \(stringsFile)")
                // Also try to set bundle for compatibility
                if let b = Bundle(path: root) { bundle = b }
                return
            }
        }

        // Last resort: try Bundle.main (works in app target at runtime)
        PeachyLog.lang.warning("Language \(lang.rawValue): no .lproj found, using fallback bundle")
        bundle = .main
    }

    private func loadStrings(at path: String) -> [String: String]? {
        // Apple .strings format: "key" = "value"; — not a standard plist.
        // Use NSString.stringByContentsOfFile + simple parsing, or try NSDictionary
        // which handles the compiled binary format used in app bundles.
        // For text-format .strings (UTF-8), parse manually.
        guard let str = try? String(contentsOfFile: path, encoding: .utf8) else {
            return NSDictionary(contentsOfFile: path) as? [String: String]
        }
        var result: [String: String] = [:]
        // Simple regex-free parser: match lines like "key" = "value";
        let lines = str.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { continue }
            // Split on " = "
            guard let eqRange = trimmed.range(of: "\" = \"") else { continue }
            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<eqRange.lowerBound])
            var value = String(trimmed[trimmed.index(eqRange.upperBound, offsetBy: 0)...])
            // Remove trailing "; and unescape
            if let semiRange = value.range(of: "\";", options: .backwards) {
                value = String(value[value.startIndex..<semiRange.lowerBound])
            } else if value.hasSuffix("\"") {
                value = String(value.dropLast())
            }
            value = value
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            result[key] = value
        }
        return result.isEmpty ? nil : result
    }

    func localizedString(forKey key: String) -> String {
        if let value = stringsCache[key] { return value }
        let result = bundle.localizedString(forKey: key, value: nil, table: nil)
        return result == key ? key : result
    }
}

func t(_ key: String) -> String {
    LanguageManager.shared.localizedString(forKey: key)
}
