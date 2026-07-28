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
    let stream: JSONValue?
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

    var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    var stringValue: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    var numberValue: Double? {
        guard case .number(let number) = self else { return nil }
        return number
    }
}

public struct ForgeStreamPointer: Equatable, Sendable {
    public let method: String
    public let requestID: String

    public init(method: String, requestID: String) {
        self.method = method
        self.requestID = requestID
    }
}

public enum ForgeStreamFrame: Equatable, Sendable {
    case snapshot(sequence: UInt64, conversations: [ActiveConversation])
    case error(sequence: UInt64, code: Int, message: String)
    case complete(sequence: UInt64)

    public var sequence: UInt64 {
        switch self {
        case .snapshot(let sequence, _), .error(let sequence, _, _), .complete(let sequence):
            return sequence
        }
    }
}

public enum ForgeRPCParser {
    public static let extensionMethod = "extension"
    public static let extensionStreamMethod = "extension/xstream"
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

    public static func makeConversationListRequest(id: String) -> RPCRequest {
        RPCRequest(id: id, method: extensionMethod, params: conversationListRootsParams)
    }

    public static func makeConversationListStreamRequest(id: String) -> RPCRequest {
        RPCRequest(id: id, method: extensionStreamMethod, params: conversationListRootsParams)
    }

    public static func parseConversationList(from data: Data, expectedID: String? = nil) throws -> [ActiveConversation] {
        let complete = try completeValue(from: data, expectedID: expectedID)
        return try parseActiveConversations(from: complete)
    }

    public static func parseStreamPointer(
        from data: Data,
        expectedID: String,
        expectedMethod: String = extensionStreamMethod
    ) throws -> ForgeStreamPointer {
        let envelope: RPCEnvelope
        do {
            envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)
        } catch {
            throw ForgeCoreError.invalidResponse(error.localizedDescription)
        }
        guard envelope.id == expectedID else {
            throw ForgeCoreError.invalidResponse("response id \(envelope.id) did not match request id \(expectedID)")
        }
        if let error = envelope.error {
            throw ForgeCoreError.rpc(code: error.code, message: error.message)
        }
        guard let stream = envelope.result?.data.stream?.objectValue,
              let method = stream["method"]?.stringValue,
              let requestID = stream["request_id"]?.stringValue,
              !requestID.isEmpty
        else {
            throw ForgeCoreError.invalidResponse("missing result.data.stream pointer")
        }
        guard method == expectedMethod else {
            throw ForgeCoreError.invalidResponse("stream method \(method) did not match \(expectedMethod)")
        }
        guard requestID == expectedID else {
            throw ForgeCoreError.invalidResponse("stream request_id \(requestID) did not match request id \(expectedID)")
        }
        return ForgeStreamPointer(method: method, requestID: requestID)
    }

    public static func parseStreamFrame(
        from data: Data,
        expectedRequestID: String,
        expectedMethod: String = extensionStreamMethod
    ) throws -> ForgeStreamFrame? {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ForgeCoreError.invalidResponse(error.localizedDescription)
        }
        guard let object = root.objectValue else {
            throw ForgeCoreError.invalidResponse("stream notification was not an object")
        }
        guard object["id"] == nil else { return nil }
        guard let method = object["method"]?.stringValue else { return nil }
        guard method == expectedMethod else { return nil }
        guard let stream = object["params"]?.objectValue?["stream"]?.objectValue,
              let requestID = stream["x-stream-request-id"]?.stringValue
        else {
            throw ForgeCoreError.invalidResponse("missing params.stream request id")
        }
        guard requestID == expectedRequestID else { return nil }
        guard let sequenceValue = stream["x-stream-seq-id"]?.numberValue,
              sequenceValue.isFinite,
              sequenceValue >= 0,
              sequenceValue.rounded(.towardZero) == sequenceValue,
              sequenceValue <= Double(UInt64.max)
        else {
            throw ForgeCoreError.invalidResponse("invalid params.stream sequence")
        }
        let sequence = UInt64(sequenceValue)
        let payloadCount = ["result", "error", "complete"].filter { stream[$0] != nil }.count
        guard payloadCount == 1 else {
            throw ForgeCoreError.invalidResponse("stream frame must contain exactly one payload")
        }
        if let result = stream["result"] {
            return .snapshot(sequence: sequence, conversations: try parseActiveConversations(from: result))
        }
        if let error = stream["error"]?.objectValue,
           let codeValue = error["code"]?.numberValue,
           codeValue.isFinite,
           codeValue.rounded(.towardZero) == codeValue,
           codeValue >= Double(Int.min), codeValue <= Double(Int.max),
           let message = error["message"]?.stringValue {
            return .error(sequence: sequence, code: Int(codeValue), message: message)
        }
        guard stream["complete"]?.objectValue != nil else {
            throw ForgeCoreError.invalidResponse("invalid stream terminal payload")
        }
        return .complete(sequence: sequence)
    }

    public static func validateNextSequence(_ sequence: UInt64, after previous: UInt64?) throws {
        if let previous, sequence != previous + 1 {
            throw ForgeCoreError.invalidResponse(
                "stream sequence \(sequence) did not follow \(previous)"
            )
        }
        if previous == nil, sequence != 0 {
            throw ForgeCoreError.invalidResponse("stream sequence started at \(sequence), expected 0")
        }
    }

    public static func parseResponseID(from data: Data) throws -> String {
        try JSONDecoder().decode(RPCEnvelope.self, from: data).id
    }

    private static var conversationListRootsParams: JSONValue {
        .object([
            "conversation_list": .object([
                "relation": .object(["type": .string("roots")])
            ])
        ])
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

    private static func parseActiveConversations(from value: JSONValue) throws -> [ActiveConversation] {
        guard let conversations = value.objectValue?["extension"]?
            .objectValue?["conversation_list"]?
            .objectValue?["conversations"]?.arrayValue
        else {
            throw ForgeCoreError.invalidResponse(
                "missing extension.conversation_list.conversations"
            )
        }

        var active: [ActiveConversation] = []
        var seen = Set<String>()
        for (index, value) in conversations.enumerated() {
            guard let object = value.objectValue,
                  let status = object["status"]?.stringValue
            else {
                throw ForgeCoreError.invalidResponse("invalid conversation at index \(index)")
            }
            guard status == "running" else { continue }
            guard let id = object["conversation_id"]?.stringValue, !id.isEmpty else {
                throw ForgeCoreError.invalidResponse("running conversation at index \(index) has invalid conversation_id")
            }
            guard seen.insert(id).inserted else {
                throw ForgeCoreError.invalidResponse("duplicate running conversation_id \(id)")
            }
            let rawTitle = object["variables"]?.objectValue?["title"]?.stringValue
            let trimmed = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            active.append(ActiveConversation(
                id: id,
                title: trimmed.isEmpty ? ActiveConversation.placeholderTitle : trimmed
            ))
        }
        return active
    }
}
