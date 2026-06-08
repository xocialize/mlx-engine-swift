import Foundation

/// Where a package's weights came from. Declared for the **process-level** provenance gate
/// (PR review + `provenance-lint`), *not* a runtime invariant — the runtime gates are license
/// (C7/C8) and SHA256 integrity. It travels with the manifest so it is introspectable, while
/// staying out of the binary's admission path. The values should match what the
/// `PackageConfiguration` actually loads (`weightsRepo` / `revision`).
public struct Provenance: Sendable, Codable, Equatable {
    public let sourceRepo: String   // e.g. "mlx-community/<name>-<quant>"
    public let revision: String     // pinned commit / revision
    public let tier: Int            // 1 / 2 / 3 (single-stack vs. multi-component pipeline)

    public init(sourceRepo: String, revision: String, tier: Int) {
        self.sourceRepo = sourceRepo
        self.revision = revision
        self.tier = tier
    }
}

/// The static, registrable description of a package — the **unit of contribution and
/// conformance**. It enters the `ToolRegistry`, runs the license gate, and answers
/// Model-Manager eligibility **without constructing the package or paging any weights**.
///
/// This is the home for everything that is *about the model*, not about one surface — which
/// is most of what a per-surface tool used to carry: the two-layer license (C7+C8),
/// cost-to-run (C10), specialty (C6), and the set of capability surfaces the one loaded model
/// exposes (C1/C11). A `ModelPackage` instance is built later, on admission, from this
/// blueprint.
public struct PackageManifest: Sendable, Codable, Equatable {
    /// The conformance-contract version this package targets (C0).
    public let contractVersion: SemanticVersion
    /// Both license layers in one place — the weight checkpoint (C7) and the port code (C8).
    public let license: LicenseDeclaration
    /// Declared weight origin for the process gate (not a runtime invariant).
    public let provenance: Provenance
    /// Cost-to-run for Model-Manager `requirements ⊆ device.capabilities` matching (C10).
    public let requirements: RequirementsManifest
    /// Model-level selection metadata (C6). Multi-valued with strength; never a surface.
    public let specialties: [SpecialtyWeight]
    /// The N capability surfaces this one model exposes (C1). Each is independently registered
    /// and introspectable through MCPBridge (C11). Lance → four entries, one loaded model.
    public let surfaces: [ToolDescriptor]

    public init(contractVersion: SemanticVersion = ContractVersion.current,
                license: LicenseDeclaration,
                provenance: Provenance,
                requirements: RequirementsManifest,
                specialties: [SpecialtyWeight] = [],
                surfaces: [ToolDescriptor]) {
        self.contractVersion = contractVersion
        self.license = license
        self.provenance = provenance
        self.requirements = requirements
        self.specialties = specialties
        self.surfaces = surfaces
    }

    /// The capabilities this package registers, derived from its surfaces (C1).
    public var capabilities: [Capability] { surfaces.map(\.capability) }
}

/// Errors a package or the engine raises around the package boundary.
public enum PackageError: Error, Sendable, Equatable {
    /// The engine handed a configuration whose type the package can't accept (factory misuse).
    case configurationMismatch(expected: String, got: String)
    /// `run(_:)` received a request for a capability this package does not back.
    case unsupportedCapability(Capability)
    /// `run(_:)` was called while the working set was not resident.
    case notLoaded
}

/// What the engine registers for a package: its static `manifest` plus a factory the engine
/// calls — license-gated, and only after `HubAssetSource` SHA256-verifies the weights — to
/// construct the instance. The license gate runs against `manifest.license` at registration;
/// construction is lazy, on first admission, and is always the engine's move, never the
/// package's (C13).
public struct PackageRegistration: Sendable {
    public let manifest: PackageManifest
    public let makePackage: @Sendable (any PackageConfiguration) throws -> any ModelPackage

    public init(manifest: PackageManifest,
                makePackage: @escaping @Sendable (any PackageConfiguration) throws -> any ModelPackage) {
        self.manifest = manifest
        self.makePackage = makePackage
    }
}

extension PackageRegistration {
    /// Build a registration from a concrete `ModelPackage` type — the one-liner an author
    /// uses to publish a package. The factory downcasts the engine-supplied configuration to
    /// the package's `Configuration`; a mismatch surfaces as `PackageError.configurationMismatch`.
    public static func of<P: ModelPackage & SendableMetatype>(_ type: P.Type) -> PackageRegistration {
        PackageRegistration(manifest: P.manifest) { config in
            guard let typed = config as? P.Configuration else {
                throw PackageError.configurationMismatch(
                    expected: String(describing: P.Configuration.self),
                    got: String(describing: Swift.type(of: config)))
            }
            return P(configuration: typed)
        }
    }
}
