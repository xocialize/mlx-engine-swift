/// Model-level metadata the Model Manager uses to rank and select (e.g. "strong at code").
///
/// Specialty is a **governed, extensible vocabulary** — registered terms, not free strings —
/// and is **never** a tool surface (C6). A model declares it multi-valued with strength.
public struct Specialty: RawRepresentable, Sendable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension Specialty {
    public static let general: Specialty = "general"
    public static let coder: Specialty = "coder"
    public static let researcher: Specialty = "researcher"
    public static let companion: Specialty = "companion"

    // characterAnimation lane ranking (contract 1.6.0): how a model is driven.
    /// No skeleton/pose dependency (e.g. SCAIL-2) — simpler to deploy.
    public static let poseless: Specialty = "poseless"
    /// Explicit pose / face-expression conditioning (e.g. Wan2.2-Animate).
    public static let poseDriven: Specialty = "poseDriven"
}

/// A specialty paired with a strength in 0...1. A model declares an array of these.
public struct SpecialtyWeight: Sendable, Codable, Equatable {
    public let specialty: Specialty
    public let strength: Double

    public init(_ specialty: Specialty, strength: Double) {
        self.specialty = specialty
        self.strength = min(max(strength, 0), 1)
    }
}
