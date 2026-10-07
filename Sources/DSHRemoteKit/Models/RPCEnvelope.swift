import Foundation

/// The `type` discriminator on an RPC envelope.
///
/// Both captures carry a fixed string, but the value is decoded through
/// ``RPCMessageType/unknown(_:)`` rather than failing, per SPEC §5: an unknown value
/// must stay readable rather than crash or force a guessed write.
public enum RPCMessageType: Hashable, Sendable {
    case clientRequest
    case serverResponse
    case unknown(String)

    public static let clientRequestRawValue = "client-request"
    public static let serverResponseRawValue = "server-response"

    public var rawValue: String {
        switch self {
        case .clientRequest: Self.clientRequestRawValue
        case .serverResponse: Self.serverResponseRawValue
        case .unknown(let value): value
        }
    }

    /// Never fails: an unrecognised string becomes ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case Self.clientRequestRawValue: self = .clientRequest
        case Self.serverResponseRawValue: self = .serverResponse
        default: self = .unknown(rawValue)
        }
    }
}

extension RPCMessageType: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RPCMessageType(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A unary RPC request: `POST /api/<method>` with this body (SPEC §6.2).
///
/// Proven by `Fixtures/rpc-request.json`. `rpcId` identifies the RPC only — SPEC
/// §6.6 forbids equating it with the human submission request ID.
public struct RPCRequest<Args: Codable & Sendable>: Codable, Sendable {
    public var type: RPCMessageType
    public var rpcId: String
    /// Must match the request path (SPEC §6.2).
    public var method: String
    public var payload: RPCPayload<Args>

    public init(rpcId: String, method: String, args: Args) {
        self.type = .clientRequest
        self.rpcId = rpcId
        self.method = method
        self.payload = RPCPayload(args: args)
    }

    /// The path this envelope must be POSTed to. Derived from SPEC §6.2, where
    /// `commands/list` is sent to `/api/commands/list`.
    public var path: String { "/api/\(method)" }
}

/// The `payload` object of ``RPCRequest``.
public struct RPCPayload<Args: Codable & Sendable>: Codable, Sendable {
    public var args: Args

    public init(args: Args) {
        self.args = args
    }
}

/// Gateway arguments are wrapped in a `_request` field on this harness generation:
/// omitting it returns `gateway/arguments-invalid` with the offending
/// `details.endpoint` (SPEC §6.2, observed live against `0.2.0-rc.2`, and visible in
/// `Fixtures/rpc-request.json`).
///
/// unverified: whether every endpoint takes exactly one `_request`, and what the
/// named-`request` variants SPEC §6.2 mentions look like, is not established by the
/// captures.
public struct RPCArguments<Request: Codable & Sendable>: Codable, Sendable {
    public var request: Request

    enum CodingKeys: String, CodingKey {
        case request = "_request"
    }

    public init(request: Request) {
        self.request = request
    }
}

/// An endpoint that takes no request fields. Decodes any JSON object, ignoring its
/// keys, so `{"_request": {}}` and future additions both work.
public struct RPCEmptyRequest: Codable, Sendable, Hashable {
    public init() {}
}

/// A unary RPC response: `HTTP 200` with this body (SPEC §6.2).
///
/// An `HTTP 200` does not establish business success — decode ``RPCResult/ok`` and
/// its typed error.
public struct RPCResponse<Value: Codable & Sendable>: Codable, Sendable {
    public var type: RPCMessageType
    /// Matches the request's `rpcId`.
    public var rpcId: String
    public var result: RPCResult<Value>
}

/// The `result` object of ``RPCResponse``.
public struct RPCResult<Value: Codable & Sendable>: Codable, Sendable {
    public var ok: Bool
    /// Absent on a refusal. `value` is present in `Fixtures/rpc-response-session-list.json`
    /// and absent in `Fixtures/rpc-response-typed-error.json`, which is what makes it
    /// optional here.
    public var value: Value?
    /// Present on a refusal.
    ///
    /// unverified: the captures never show `ok: true` with an `error`, so the pair's
    /// exclusivity is assumed rather than proven.
    public var error: RPCError?
}

/// A business error carried inside a successful HTTP response (SPEC §6.2, §6.9
/// "Business refusal").
///
/// Proven by `Fixtures/rpc-response-typed-error.json`. `code` is an opaque namespaced
/// string such as `gateway/arguments-invalid`; it is not an enum, because the host's
/// full code list is not established by the captures.
public struct RPCError: Codable, Sendable, Hashable {
    public var code: String
    /// Readable reason. SPEC §6.9: show it and retain the user's input.
    public var message: String
    public var details: RPCErrorDetails?

    public init(code: String, message: String, details: RPCErrorDetails? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// The `details` object of ``RPCError``.
///
/// Only `endpoint` is proven by the capture; other keys on other error codes are
/// preserved here as ``unknownFields`` rather than dropped, so a diagnostic export
/// can still show them.
public struct RPCErrorDetails: Codable, Sendable, Hashable {
    /// The endpoint the gateway rejected, e.g. `session/list`.
    public var endpoint: String?
    /// Any further keys the host sent. Unverified shape: kept losslessly.
    public var unknownFields: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case endpoint
    }

    public init(endpoint: String? = nil, unknownFields: [String: JSONValue] = [:]) {
        self.endpoint = endpoint
        self.unknownFields = unknownFields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        // Re-read the same object losslessly to keep keys this build does not know.
        let raw = try decoder.container(keyedBy: DynamicKey.self)
        var extras: [String: JSONValue] = [:]
        for key in raw.allKeys where key.stringValue != CodingKeys.endpoint.rawValue {
            extras[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
        }
        unknownFields = extras
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        if let endpoint {
            try container.encode(endpoint, forKey: DynamicKey(CodingKeys.endpoint.rawValue))
        }
        for (key, value) in unknownFields {
            try container.encode(value, forKey: DynamicKey(key))
        }
    }
}

/// Coding key for objects whose keys are not known at compile time.
struct DynamicKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) { nil }
}
