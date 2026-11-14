import Foundation

/// Any JSON value. The openGym state document is kept in this form so keys Hexplate does not
/// understand (sync stamps, settings of features it lacks) survive a load and save untouched.
/// Numbers are `Double`, exactly as in JavaScript, where the document comes from.
public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool before number: JSONDecoder refuses to read `true` as a number and `1` as a Bool,
        // so the two never get mixed up.
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var numberValue: Double? { if case .number(let v) = self { v } else { nil } }

    /// Reads this value as a typed model.
    // ponytail: goes through JSON text again; write a direct decoder if a profile ever loads slowly.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}
