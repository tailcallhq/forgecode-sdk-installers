import Foundation

public struct RPCRequest: Encodable, Equatable, Sendable {
    public let jsonrpc = "2.0"
    public let id: String
    public let method: String
    public let params: JSONValue?

    public init(id: String, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct RPCEnvelope: Decodable {
    let id: String
    let result: RPCResult?
    let error: RPCErrorPayload?
}

private struct RPCResult: Decodable {
    let data: RPCData
}

private struct RPCData: Decodable {
    let complete: JSONValue?
}

private struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }
}

public enum ForgeRPCParser {
    public static let discoverMethod = "rpc.discover"

    public static func makeDiscoverRequest(id: String) -> RPCRequest {
        RPCRequest(id: id, method: discoverMethod, params: nil)
    }

    /// Reads `result.data.complete["rpc.discover"].info.version`, the SDK
    /// version advertised by the host's OpenRPC discovery document.
    public static func parseSDKVersion(from data: Data, expectedID: String? = nil) throws -> String {
        let complete = try completeValue(from: data, expectedID: expectedID)
        guard let version = complete.objectValue?[discoverMethod]?
            .objectValue?["info"]?
            .objectValue?["version"]?.stringValue
        else {
            throw ForgeCoreError.invalidResponse("missing \(discoverMethod).info.version")
        }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ForgeCoreError.invalidResponse("\(discoverMethod).info.version was empty")
        }
        return trimmed
    }

    public static func parseResponseID(from data: Data) throws -> String {
        try JSONDecoder().decode(RPCEnvelope.self, from: data).id
    }

    private static func completeValue(from data: Data, expectedID: String?) throws -> JSONValue {
        let envelope: RPCEnvelope
        do {
            envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)
        } catch {
            throw ForgeCoreError.invalidResponse(error.localizedDescription)
        }
        if let expectedID, envelope.id != expectedID {
            throw ForgeCoreError.invalidResponse("response id \(envelope.id) did not match request id \(expectedID)")
        }
        if let error = envelope.error {
            throw ForgeCoreError.rpc(code: error.code, message: error.message)
        }
        guard let complete = envelope.result?.data.complete else {
            throw ForgeCoreError.invalidResponse("response was not complete")
        }
        return complete
    }
}
