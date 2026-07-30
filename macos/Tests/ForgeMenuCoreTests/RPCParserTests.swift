import XCTest
@testable import ForgeMenuCore

final class RPCParserTests: XCTestCase {
    func testRejectsNumericRPCID() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"data":{"complete":{}}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseResponseID(from: data))
    }

    func testDiscoverRequestAndVersionParsing() throws {
        let request = ForgeRPCParser.makeDiscoverRequest(id: "discover-1")
        XCTAssertEqual(request.method, "rpc.discover")
        XCTAssertNil(request.params)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? String, "discover-1")
        XCTAssertEqual(object["method"] as? String, "rpc.discover")

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

    func testRPCErrorEnvelopeSurfacesCodeAndMessage() {
        let data = Data(#"{"jsonrpc":"2.0","id":"d","error":{"code":-32601,"message":"method not found"}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseSDKVersion(from: data, expectedID: "d")) { error in
            XCTAssertEqual(
                error as? ForgeCoreError,
                .rpc(code: -32601, message: "method not found")
            )
        }
    }

    func testIncompleteResponseIsRejected() {
        let data = Data(#"{"jsonrpc":"2.0","id":"d","result":{"data":{}}}"#.utf8)
        XCTAssertThrowsError(try ForgeRPCParser.parseSDKVersion(from: data, expectedID: "d"))
    }
}
