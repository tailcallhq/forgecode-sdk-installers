import Foundation

public enum ConsoleURLBuilder {
    public static let defaultOrigin = "https://console.forgecode.dev"
    public static let environmentKey = "FORGE_CONSOLE_ORIGIN"

    public static func resolvedOrigin(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let environmentValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environmentValue, !environmentValue.isEmpty else {
            return try validateOrigin(defaultOrigin)
        }
        return try validateOrigin(environmentValue)
    }

    public static func validateOrigin(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url
        else {
            throw ForgeCoreError.invalidConsoleOrigin(value)
        }
        return url
    }

    /// The frontend accepts `?connect=<host>:<port>` to target a specific
    /// `forge3 ws` backend, so links can carry the running endpoint directly.
    public static let connectQueryItem = "connect"

    public static func consoleURL(origin: URL, endpoint: LoopbackEndpoint?) throws -> URL {
        try buildURL(origin: origin, percentEncodedPath: "/", endpoint: endpoint)
    }

    public static func conversationURL(
        conversationID: String,
        origin: URL,
        endpoint: LoopbackEndpoint? = nil
    ) throws -> URL {
        guard !conversationID.isEmpty else {
            throw ForgeCoreError.invalidResponse("conversation_id was empty")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encodedID = conversationID.addingPercentEncoding(withAllowedCharacters: allowed),
              !encodedID.isEmpty
        else {
            throw ForgeCoreError.invalidResponse("conversation_id could not be encoded")
        }
        return try buildURL(origin: origin, percentEncodedPath: "/c/\(encodedID)", endpoint: endpoint)
    }

    private static func buildURL(
        origin: URL,
        percentEncodedPath: String,
        endpoint: LoopbackEndpoint?
    ) throws -> URL {
        let validatedOrigin = try validateOrigin(origin.absoluteString)
        guard var components = URLComponents(url: validatedOrigin, resolvingAgainstBaseURL: false) else {
            throw ForgeCoreError.invalidResponse("console URL could not be constructed")
        }
        components.percentEncodedPath = percentEncodedPath
        components.fragment = nil
        if let endpoint {
            components.queryItems = [URLQueryItem(name: connectQueryItem, value: endpoint.address)]
        } else {
            components.query = nil
        }
        guard let url = components.url else {
            throw ForgeCoreError.invalidResponse("console URL could not be constructed")
        }
        return url
    }
}
