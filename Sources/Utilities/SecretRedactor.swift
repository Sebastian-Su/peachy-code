import Foundation

/// Replaces credential values in free text (commands, prompts, notification
/// bodies) with a placeholder before they are written to disk.
enum SecretRedactor {
    static let placeholder = "<redacted>"

    private static let patterns: [NSRegularExpression] = [
        // Authorization: Bearer xxx / Authorization=Basic xxx / "Authorization":"xxx"
        #"(?i)(authorization"?\s*[:=]\s*"?(?:(?:bearer|basic|token)\s+)?)(?!<redacted>)(?!(?:bearer|basic|token)\b)[^\s"'\\,}<]+"#,
        // A bare "Bearer <token>" elsewhere; tokens are long, so "the Bearer of" is left alone.
        #"(?i)(\bbearer\s+)(?!<redacted>)(?=[A-Za-z0-9._~+/=-]*[0-9._-])[A-Za-z0-9._~+/=-]{8,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func redact(_ text: String) -> String {
        guard text.range(of: "authorization", options: .caseInsensitive) != nil
            || text.range(of: "bearer", options: .caseInsensitive) != nil else { return text }
        var result = text
        for pattern in patterns {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1\(placeholder)")
        }
        return result
    }

    /// Redacts every string in a JSON object tree.
    static func redactJSON(_ value: Any) -> Any {
        switch value {
        case let string as String: return redact(string)
        case let array as [Any]: return array.map(redactJSON)
        case let dict as [String: Any]: return dict.mapValues(redactJSON)
        default: return value
        }
    }
}
