import Foundation

public enum Redactor {
    private static let sensitiveKeys: Set<String> = [
        "access_token", "accesstoken", "refresh_token", "refreshtoken",
        "api_key", "apikey", "authorization", "cookie", "set_cookie",
        "secret", "client_secret", "password", "passwd", "token"
    ]
    private static let sensitiveKeyPattern = try! NSRegularExpression(
        pattern: #"(?i)(access[_-]?token|refresh[_-]?token|api[_-]?key|authorization|secret|password)\s*[=:]\s*(?:Bearer\s+)?[^\s,;}\]]+"#
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#
    )
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\b(?:(?:sk|pk|xox[baprs])-|(?:ghp|github_pat)_)[-A-Za-z0-9_]{8,}\b"#
    )

    public static func redact(_ value: String) -> String {
        let jsonRedacted = redactJSONIfPossible(value) ?? value
        let range = NSRange(jsonRedacted.startIndex..<jsonRedacted.endIndex, in: jsonRedacted)
        var redacted = sensitiveKeyPattern.stringByReplacingMatches(
            in: jsonRedacted,
            range: range,
            withTemplate: "$1=<redacted>"
        )
        redacted = bearerPattern.stringByReplacingMatches(
            in: redacted,
            range: NSRange(redacted.startIndex..<redacted.endIndex, in: redacted),
            withTemplate: "Bearer <redacted>"
        )
        redacted = tokenPattern.stringByReplacingMatches(
            in: redacted,
            range: NSRange(redacted.startIndex..<redacted.endIndex, in: redacted),
            withTemplate: "<redacted>"
        )
        return redacted
    }

    private static func redactJSONIfPossible(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(
                  withJSONObject: redactJSONObject(object),
                  options: [.sortedKeys]
              )
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private static func redactJSONObject(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, element in
                let normalized = element.key
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                result[element.key] = sensitiveKeys.contains(normalized)
                    ? "<redacted>"
                    : redactJSONObject(element.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redactJSONObject)
        }
        if let string = value as? String {
            return redact(string)
        }
        return value
    }
}
