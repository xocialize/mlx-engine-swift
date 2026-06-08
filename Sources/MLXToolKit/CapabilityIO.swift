/// A capability's canonical request type. Carries the common envelope fields shared by
/// every request: the per-request `mode` tag (C4) and package-specific `metaData` (C5).
public protocol CapabilityRequest: Sendable {
    /// The capability this request targets. Must match the tool's `capability` (C1/C2).
    static var capability: Capability { get }
    /// Per-request mode tag, within the capability. Optional.
    var mode: Mode? { get }
    /// Package-specific steering only.
    var metaData: MetaData { get }
}

extension CapabilityRequest {
    /// The capability this request targets, readable from an existential (`any
    /// CapabilityRequest`) so a `ModelPackage.run(_:)` can dispatch on it without reaching for
    /// `type(of:)`.
    public var capability: Capability { Self.capability }
}

/// A capability's canonical response type. The concrete response carries the canonical
/// output artifact for its capability (e.g. TTS -> Audio).
public protocol CapabilityResponse: Sendable {}
