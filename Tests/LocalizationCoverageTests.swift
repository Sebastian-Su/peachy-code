import XCTest

/// Every key the app looks up with t("…") must exist in both languages, so
/// switching language never shows a raw key (S26).
final class LocalizationCoverageTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func keys(_ lang: String) throws -> Set<String> {
        let url = root.appendingPathComponent("Sources/Resources/\(lang).lproj/Localizable.strings")
        // Read keys the way LanguageManager does: line by line, `"key" = "value";`.
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^"([^"]+)"\s*="#, options: .anchorsMatchLines)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    private func usedKeys() throws -> Set<String> {
        let sources = root.appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\bt\("([a-z_]+\.[a-z0-9_.]+)"\)"#)
        var used = Set<String>()
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range(at: 1), in: text) { used.insert(String(text[r])) }
            }
        }
        // Not translation keys: file names passed through t() by mistake are not used this way.
        return used.filter { !$0.hasSuffix(".json") && !$0.hasSuffix(".jsonl") }
    }

    func testBothLanguagesHaveTheSameKeys() throws {
        XCTAssertEqual(try keys("en"), try keys("zh"))
    }

    func testEveryUsedKeyIsTranslated() throws {
        let en = try keys("en"), zh = try keys("zh")
        let used = try usedKeys()
        XCTAssertEqual(used.subtracting(en).sorted(), [], "missing in en")
        XCTAssertEqual(used.subtracting(zh).sorted(), [], "missing in zh")
    }

    func testMainWindowShowsNoHardCodedEnglish() throws {
        let files = ["Sources/Views/Peachy/PeachyDashboardView.swift", "Sources/Views/Settings/SettingsView.swift"]
        let banned = [#"Text("Masko Library")"#, #"Label("Create""#, #"Text("Activate")"#, #"Text("Hide")"#,
                      #""Uninstall Peachy?""#]
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for literal in banned where text.contains(literal) {
                XCTFail("\(file) still hard-codes \(literal)")
            }
        }
    }
}
