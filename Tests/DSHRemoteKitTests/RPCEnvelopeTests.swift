import Foundation
import Testing

@testable import DSHRemoteKit

@Test("rpc-request.json decodes into the unary request envelope")
func rpcRequestDecodes() throws {
    let request = try Fixtures.decode(
        RPCRequest<RPCArguments<RPCEmptyRequest>>.self,
        .rpcRequest
    )

    #expect(request.type == .clientRequest)
    #expect(request.rpcId == "fixture-capture")
    #expect(request.method == "session/list")
    #expect(request.path == "/api/session/list")

    let object = try Fixtures.object(.rpcRequest)
    #expect(Set(object.keys) == ["type", "rpcId", "method", "payload"])
    let payload = try #require(object["payload"]?.objectValue)
    #expect(Set(payload.keys) == ["args"])
    // SPEC §6.2: this harness generation wraps arguments in `_request`.
    let args = try #require(payload["args"]?.objectValue)
    #expect(Set(args.keys) == ["_request"])
    #expect(args["_request"]?.objectValue == [:])
}

@Test("an RPC request re-encodes to the captured shape")
func rpcRequestEncodes() throws {
    let request = RPCRequest(rpcId: "fixture-capture", method: "session/list", args: RPCArguments(request: RPCEmptyRequest()))
    let object = try #require(
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request)).objectValue
    )

    #expect(object["type"]?.stringValue == "client-request")
    #expect(object["rpcId"]?.stringValue == "fixture-capture")
    #expect(object["method"]?.stringValue == "session/list")
    #expect(object["payload"]?["args"]?.objectValue?["_request"]?.objectValue == [:])
}

@Test("args carry a typed request body, not only an empty object")
func rpcRequestCarriesTypedArgs() throws {
    // `session/list` is the only captured method, so this only proves the envelope
    // survives an arbitrary object body — not any endpoint's field names.
    let body = ["sessionId": JSONValue.string("session-0001"), "limit": JSONValue.int(20)]
    let request = RPCRequest(rpcId: "r-1", method: "session/list", args: RPCArguments(request: body))
    let data = try JSONEncoder().encode(request)
    let roundTripped = try JSONDecoder().decode(RPCRequest<RPCArguments<[String: JSONValue]>>.self, from: data)

    #expect(roundTripped.payload.args.request["sessionId"]?.stringValue == "session-0001")
    #expect(roundTripped.payload.args.request["limit"]?.intValue == 20)
}

@Test("rpc-response-typed-error.json surfaces both code and endpoint")
func typedErrorSurfacesCodeAndEndpoint() throws {
    let response = try Fixtures.decode(RPCResponse<JSONValue>.self, .rpcTypedError)

    #expect(response.type == .serverResponse)
    #expect(response.rpcId == "fixture-capture")
    #expect(response.result.ok == false)
    #expect(response.result.value == nil)

    let error = try #require(response.result.error)
    #expect(error.code == "gateway/arguments-invalid")
    #expect(
        error.message
            == "typert gateway: session/list: args fields do not match the descriptor: missing \"_request\""
    )
    #expect(error.details?.endpoint == "session/list")

    // HTTP 200 is not success: the refusal is only visible through `result.ok`.
    let object = try Fixtures.object(.rpcTypedError)
    #expect(object["result"]?["ok"]?.boolValue == false)
    #expect(object["result"]?.objectValue?["value"] == nil)
}

@Test("error details keep keys this build does not know")
func errorDetailsKeepUnknownKeys() throws {
    let response = try Fixtures.decode(
        RPCResponse<JSONValue>.self,
        mutatedFrom: .rpcTypedError,
        setting: [
            "result": .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string("gateway/unknown-thing"),
                    "message": .string("no idea"),
                    "details": .object([
                        "endpoint": .string("session/list"),
                        "retryAfterMs": .int(60_000),
                        "hint": .object(["deep": .array([.bool(true)])]),
                    ]),
                ]),
            ]),
        ]
    )

    let error = try #require(response.result.error)
    #expect(error.code == "gateway/unknown-thing")
    #expect(error.details?.endpoint == "session/list")
    #expect(error.details?.unknownFields["retryAfterMs"]?.intValue == 60_000)
    #expect(error.details?.unknownFields["hint"] != nil)
}

@Test("an unrecognised envelope type decodes instead of failing")
func unknownMessageTypeTolerated() throws {
    let response = try Fixtures.decode(
        RPCResponse<JSONValue>.self,
        mutatedFrom: .rpcTypedError,
        setting: ["type": .string("server-stream-frame")]
    )

    #expect(response.type == .unknown("server-stream-frame"))
    #expect(response.type.rawValue == "server-stream-frame")
    #expect(response.result.error?.details?.endpoint == "session/list")
}

@Test("a typed error on an ok response decodes rather than being assumed impossible")
func okResponseWithUnexpectedErrorDecodes() throws {
    let response = try Fixtures.decode(
        RPCResponse<JSONValue>.self,
        mutatedFrom: .rpcTypedError,
        setting: [
            "result": .object([
                "ok": .bool(true),
                "value": .object(["echo": .string("surprise")]),
                "error": .object(["code": .string("weird"), "message": .string("both")]),
            ]),
        ]
    )

    #expect(response.result.ok == true)
    #expect(response.result.value?["echo"]?.stringValue == "surprise")
    #expect(response.result.error?.code == "weird")
}

@Test("an ok response with no value decodes")
func okResponseWithoutValueDecodes() throws {
    let response = try Fixtures.decode(
        RPCResponse<JSONValue>.self,
        mutatedFrom: .rpcTypedError,
        setting: ["result": .object(["ok": .bool(true)])]
    )

    #expect(response.result.ok == true)
    #expect(response.result.value == nil)
    #expect(response.result.error == nil)
}

@Test("unknown envelope keys are ignored, not fatal")
func unknownEnvelopeKeysTolerated() throws {
    let response = try Fixtures.decode(
        RPCResponse<JSONValue>.self,
        mutatedFrom: .rpcTypedError,
        setting: [
            "traceId": .string("abc"),
            "serverVersion": .string("0.2.0-rc.2"),
            "attempts": .array([.int(1), .int(2)]),
        ]
    )

    #expect(response.rpcId == "fixture-capture")
    #expect(response.result.error?.code == "gateway/arguments-invalid")
}

@Test("a non-string type is a malformed envelope, reported as a decode failure")
func nonStringTypeFailsToDecode() throws {
    // SPEC §6.9 treats a malformed response as a protocol incompatibility, so this must
    // throw rather than silently accept a shape the app cannot reason about.
    #expect(throws: (any Error).self) {
        try Fixtures.decode(
            RPCResponse<JSONValue>.self,
            mutatedFrom: .rpcTypedError,
            setting: ["type": .int(7)]
        )
    }
}

@Test("method and path stay in step")
func requestPathFollowsMethod() {
    let request = RPCRequest(rpcId: "r", method: "commands/list", args: RPCArguments(request: RPCEmptyRequest()))
    #expect(request.path == "/api/commands/list")
}
