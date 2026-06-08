/// A per-request tag *within* a capability (e.g. LLM `thinking` / `direct` / `companion`).
///
/// Mode rides the request envelope as a parameter and is **never** a separate tool surface
/// (C4). Modes are open and extensible; a capability documents the modes it honors.
public struct Mode: RawRepresentable, Sendable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension Mode {
    // Canonical LLM response modes. Thinking is poor for companion use — hence the tag,
    // not a separate `chatCompanion` surface.
    public static let thinking: Mode = "thinking"
    public static let direct: Mode = "direct"
    public static let companion: Mode = "companion"
}
