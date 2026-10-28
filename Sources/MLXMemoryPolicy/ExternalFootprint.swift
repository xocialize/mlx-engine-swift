/// The bytes a non-package GPU tenant holds, in the engine's own persistent + transient split
/// (contract 1.43.0). `persistentBytes` is held between uses — a layer-texture cache, pooled
/// working textures — and counts in residency exactly like a package's weights.
/// `transientBytes` is what one use of the tenant adds on top — upload staging, readback — and
/// is reserved IN ADDITION to the packages' one serialized transient, never folded into its max
/// (see `MLXServeEngine.registerExternalTenant`).
///
/// In MLXMemoryPolicy since 1.58.0 (and `Codable`), so a host outside the engine can declare the
/// same split to `MemoryPolicy`.
public struct ExternalFootprint: Sendable, Equatable, Hashable, Codable {
    public var persistentBytes: UInt64
    public var transientBytes: UInt64

    public init(persistentBytes: UInt64 = 0, transientBytes: UInt64 = 0) {
        self.persistentBytes = persistentBytes
        self.transientBytes = transientBytes
    }

    public var totalBytes: UInt64 { persistentBytes &+ transientBytes }
    public static let zero = ExternalFootprint()
}
