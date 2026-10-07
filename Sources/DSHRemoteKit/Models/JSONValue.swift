import Foundation

/// A lossless JSON value, used wherever the captured fixtures do not prove a
/// concrete shape. Decoding one can never fail on an unrecognised value, which is
/// what SPEC §5 requires of every host-supplied structure: "Decode unknown keys
/// tolerantly … never let an unknown shape crash".
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case int(Int64)
    case double(Double)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            // Unreachable for valid JSON: the branches above cover every JSON type.
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSONValue"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int64? {
        switch self {
        case .int(let v): v
        case .double(let v): v.rounded() == v ? Int64(exactly: v) : nil
        default: nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let values = arrayValue, values.indices.contains(index) else { return nil }
        return values[index]
    }
}
