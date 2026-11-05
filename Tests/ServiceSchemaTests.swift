import XCTest
@testable import PeachyPet

/// The JSON Schema shipped for agents and the app's parser must accept and
/// reject the same files (S6).
final class ServiceSchemaTests: XCTestCase {
    private var schema: [String: Any]!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/service-registry.schema.json")
        schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Minimal validator for the keywords the schema uses.
    private func schemaAccepts(_ doc: Any) -> Bool {
        guard let obj = doc as? [String: Any] else { return false }
        for key in schema["required"] as? [String] ?? [] where obj[key] == nil { return false }
        let props = schema["properties"] as? [String: [String: Any]] ?? [:]
        for (key, value) in obj {
            guard let rule = props[key] else { continue }
            switch rule["type"] as? String {
            case "string":
                guard let s = value as? String else { return false }
                if let min = rule["minLength"] as? Int, s.trimmingCharacters(in: .whitespacesAndNewlines).count < min { return false }
                if let allowed = rule["enum"] as? [String], !allowed.contains(s) { return false }
            case "integer":
                guard let num = value as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue == num.doubleValue.rounded() else { return false }
                let n = num.intValue
                if let c = rule["const"] as? Int, n != c { return false }
                if let lo = rule["minimum"] as? Int, n < lo { return false }
                if let hi = rule["maximum"] as? Int, n > hi { return false }
            case "object":
                guard let d = value as? [String: Any] else { return false }
                if (rule["additionalProperties"] as? [String: Any])?["type"] as? String == "string",
                   d.values.contains(where: { !($0 is String) }) { return false }
            default: break
            }
        }
        return true
    }

    func testSchemaAndParserAgreeOnSamples() throws {
        let samples: [String] = [
            #"{"schema":1,"name":"A","kind":"service","command":"x"}"#,
            #"{"schema":1,"name":"A","kind":"task","command":"x","cwd":"~/a","url":"http://x","port":8188,"env":{"K":"v"},"note":"n","extra":true}"#,
            #"{"schema":1,"name":"A","kind":"daemon","command":"x"}"#,
            #"{"schema":2,"name":"A","kind":"service","command":"x"}"#,
            #"{"schema":1,"kind":"service","command":"x"}"#,
            #"{"schema":1,"name":"A","kind":"service"}"#,
            #"{"name":"A","kind":"service","command":"x"}"#,
            #"{"schema":1,"name":"  ","kind":"service","command":"x"}"#,
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, sample) in samples.enumerated() {
            let file = dir.appendingPathComponent("s\(i).json")
            try Data(sample.utf8).write(to: file)
            let parserOK: Bool
            if case .valid = ServiceRegistry.parse(fileURL: file, id: "s\(i)") { parserOK = true } else { parserOK = false }
            let schemaOK = schemaAccepts(try JSONSerialization.jsonObject(with: Data(sample.utf8)))
            XCTAssertEqual(parserOK, schemaOK, "sample \(i): \(sample)")
        }
    }
}
