import XCTest
@testable import ForgeMenuCore

final class RPCParserTests: XCTestCase {
    func testRootsRequestsUseExactExternallyTaggedExtensionWire() throws {
        let oneShot = ForgeRPCParser.makeConversationListRequest(id: "list-1")
        let stream = ForgeRPCParser.makeConversationListStreamRequest(id: "stream-1")

        XCTAssertEqual(oneShot.method, "extension")
        XCTAssertEqual(stream.method, "extension/xstream")

        for request in [oneShot, stream] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
            )
            XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(object["id"] as? String, request.id)
            XCTAssertEqual(object["method"] as? String, request.method)
            let params = try XCTUnwrap(object["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), ["conversation_list"])
            let conversationList = try XCTUnwrap(params["conversation_list"] as? [String: Any])
            XCTAssertEqual(Set(conversationList.keys), ["relation"])
            let relation = try XCTUnwrap(conversationList["relation"] as? [String: Any])
            XCTAssertEqual(relation["type"] as? String, "roots")
        }
    }

    func testValidatesExactExtensionXStreamPointer() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"stream-1","result":{"data":{"stream":{"method":"extension/xstream","request_id":"stream-1"}}}}"#.utf8)
        XCTAssertEqual(
            try ForgeRPCParser.parseStreamPointer(from: data, expectedID: "stream-1"),
            ForgeStreamPointer(method: "extension/xstream", requestID: "stream-1")
        )

        let oldIncorrectMethod = Data(#"{"jsonrpc":"2.0","id":"stream-1","result":{"data":{"stream":{"method":"conversation_list/xstream","request_id":"stream-1"}}}}"#.utf8)
        XCTAssertThrowsError(
            try ForgeRPCParser.parseStreamPointer(from: oldIncorrectMethod, expectedID: "stream-1")
        )

        let oneShotMethod = Data(#"{"jsonrpc":"2.0","id":"stream-1","result":{"data":{"stream":{"method":"extension","request_id":"stream-1"}}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseStreamPointer(from: oneShotMethod, expectedID: "stream-1"))

        let wrongRequest = Data(#"{"jsonrpc":"2.0","id":"stream-1","result":{"data":{"stream":{"method":"extension/xstream","request_id":"other"}}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseStreamPointer(from: wrongRequest, expectedID: "stream-1"))
    }

    func testParsesAuthoritativeRunningSnapshotFromExtensionXStreamNotification() throws {
        let data = Data(#"""
        {"jsonrpc":"2.0","method":"extension/xstream","params":{"stream":{
          "x-stream-request-id":"stream-1","x-stream-seq-id":0,
          "result":{"extension":{"conversation_list":{"conversations":[
            {"conversation_id":"running-1","status":"running","variables":{"title":"  Active root  "}},
            {"conversation_id":"idle-1","status":"idle","variables":{"title":"Ignored"}},
            {"conversation_id":"running-2","status":"running","variables":{"title":"  "}}
          ]}}}
        }}}
        """#.utf8)

        XCTAssertEqual(
            try ForgeRPCParser.parseStreamFrame(from: data, expectedRequestID: "stream-1"),
            .snapshot(sequence: 0, conversations: [
                ActiveConversation(id: "running-1", title: "Active root"),
                ActiveConversation(id: "running-2", title: "Untitled")
            ])
        )
    }

    func testIgnoresOldIncorrectNotificationMethodOtherMethodsAndRequestIDs() throws {
        let oldIncorrectMethod = Data(#"{"jsonrpc":"2.0","method":"conversation_list/xstream","params":{"stream":{"x-stream-request-id":"stream-1","x-stream-seq-id":0,"complete":{}}}}"#.utf8)
        XCTAssertNil(try ForgeRPCParser.parseStreamFrame(from: oldIncorrectMethod, expectedRequestID: "stream-1"))

        let otherMethod = Data(#"{"jsonrpc":"2.0","method":"other/xstream","params":{"stream":{"x-stream-request-id":"stream-1","x-stream-seq-id":0,"complete":{}}}}"#.utf8)
        XCTAssertNil(try ForgeRPCParser.parseStreamFrame(from: otherMethod, expectedRequestID: "stream-1"))

        let otherRequest = Data(#"{"jsonrpc":"2.0","method":"extension/xstream","params":{"stream":{"x-stream-request-id":"stream-2","x-stream-seq-id":0,"complete":{}}}}"#.utf8)
        XCTAssertNil(try ForgeRPCParser.parseStreamFrame(from: otherRequest, expectedRequestID: "stream-1"))
    }

    func testParsesExtensionXStreamErrorAndComplete() throws {
        let error = Data(#"{"jsonrpc":"2.0","method":"extension/xstream","params":{"stream":{"x-stream-request-id":"s","x-stream-seq-id":3,"error":{"code":-32000,"message":"lost"}}}}"#.utf8)
        XCTAssertEqual(
            try ForgeRPCParser.parseStreamFrame(from: error, expectedRequestID: "s"),
            .error(sequence: 3, code: -32000, message: "lost")
        )
        let complete = Data(#"{"jsonrpc":"2.0","method":"extension/xstream","params":{"stream":{"x-stream-request-id":"s","x-stream-seq-id":4,"complete":{}}}}"#.utf8)
        XCTAssertEqual(
            try ForgeRPCParser.parseStreamFrame(from: complete, expectedRequestID: "s"),
            .complete(sequence: 4)
        )
    }

    func testSequenceMustStartAtZeroAndRemainContiguous() {
        XCTAssertNoThrow(try ForgeRPCParser.validateNextSequence(0, after: nil))
        XCTAssertNoThrow(try ForgeRPCParser.validateNextSequence(1, after: 0))
        XCTAssertThrowsError(try ForgeRPCParser.validateNextSequence(2, after: nil))
        XCTAssertThrowsError(try ForgeRPCParser.validateNextSequence(3, after: 1))
        XCTAssertThrowsError(try ForgeRPCParser.validateNextSequence(1, after: 1))
    }

    func testReplacementSnapshotsDoNotMergeAndRejectMalformedRunningEntries() throws {
        let first = try snapshot(#"[{"conversation_id":"a","status":"running","variables":{"title":"A"}},{"conversation_id":"b","status":"running","variables":{"title":"B"}}]"#)
        let second = try snapshot(#"[{"conversation_id":"b","status":"running","variables":{"title":"B2"}}]"#, sequence: 1)
        guard case .snapshot(_, let firstValues) = first,
              case .snapshot(_, let secondValues) = second else {
            return XCTFail("expected snapshots")
        }
        XCTAssertEqual(firstValues.map(\.id), ["a", "b"])
        XCTAssertEqual(secondValues, [ActiveConversation(id: "b", title: "B2")])

        let missingID = Data(#"{"jsonrpc":"2.0","method":"extension/xstream","params":{"stream":{"x-stream-request-id":"s","x-stream-seq-id":0,"result":{"extension":{"conversation_list":{"conversations":[{"status":"running","variables":{"title":"Bad"}}]}}}}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseStreamFrame(from: missingID, expectedRequestID: "s"))
    }

    func testOneShotParserKeepsNestedExtensionResponsePath() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":"list-1","result":{"data":{"complete":{"extension":{"conversation_list":{"conversations":[{"conversation_id":"a","status":"running","variables":{"title":"A"}}]}}}}}}"#.utf8)
        XCTAssertEqual(
            try ForgeRPCParser.parseConversationList(from: data, expectedID: "list-1"),
            [ActiveConversation(id: "a", title: "A")]
        )
        let wrongPath = Data(#"{"jsonrpc":"2.0","id":"list-1","result":{"data":{"complete":{"conversation_list":{"conversations":[]}}}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseConversationList(from: wrongPath, expectedID: "list-1"))
    }

    func testRejectsNumericRPCID() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"data":{"complete":{}}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseResponseID(from: data))
    }

    func testDiscoverRequestAndVersionParsing() throws {
        let request = ForgeRPCParser.makeDiscoverRequest(id: "discover-1")
        XCTAssertEqual(request.method, "rpc.discover")
        XCTAssertNil(request.params)

        let data = Data(#"""
        {"jsonrpc":"2.0","id":"discover-1","result":{"x-execution-time":4,"data":{"complete":{"rpc.discover":{"openrpc":"1.4.0","info":{"title":"Forge Agent SDK","version":" 0.1.0 "},"methods":[]}}}}}
        """#.utf8)
        XCTAssertEqual(try ForgeRPCParser.parseSDKVersion(from: data, expectedID: "discover-1"), "0.1.0")
        XCTAssertThrowsError(try ForgeRPCParser.parseSDKVersion(from: data, expectedID: "other"))

        let blank = Data(#"""
        {"jsonrpc":"2.0","id":"d","result":{"data":{"complete":{"rpc.discover":{"info":{"version":"  "}}}}}}
        """#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseSDKVersion(from: blank, expectedID: "d"))

        let missing = Data(#"""
        {"jsonrpc":"2.0","id":"d","result":{"data":{"complete":{"rpc.discover":{"info":{}}}}}}
        """#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseSDKVersion(from: missing, expectedID: "d"))
    }

    private func snapshot(_ conversationsJSON: String, sequence: UInt64 = 0) throws -> ForgeStreamFrame? {
        let data = Data("""
        {"jsonrpc":"2.0","method":"extension/xstream","params":{"stream":{
          "x-stream-request-id":"s","x-stream-seq-id":\(sequence),
          "result":{"extension":{"conversation_list":{"conversations":\(conversationsJSON)}}}
        }}}
        """.utf8)
        return try ForgeRPCParser.parseStreamFrame(from: data, expectedRequestID: "s")
    }
}
