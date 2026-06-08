import Foundation

/// Free-form, package-specific steering passed through the engine opaquely.
///
/// `metaData` is for *genuinely package-specific* extras only. Anything common across
/// packages of the same capability belongs in that capability's canonical schema, not here
/// (C5). Reviewers reject should-be-canonical parameters smuggled into `metaData`.
public typealias MetaData = [String: MetaValue]

/// A JSON-like value usable in `metaData` and request parameters.
public indirect enum MetaValue: Sendable, Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([MetaValue])
    case object([String: MetaValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([MetaValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: MetaValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported MetaValue")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
