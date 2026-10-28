import Foundation

/// A package configuration's memory and weight facts, resolved and exported as data (contract
/// 1.57.0, AB-A-0206 item 1).
///
/// The engine resolves these at `register()` from a live configuration object: which
/// `QuantFootprint` applies, which `FootprintConfigured` hints override it, which weights the lane
/// needs and who downloads them. A host that schedules memory across worker PROCESSES (Gaea's
/// plugins) has no configuration object and links no MLX, so the same resolution is exported here
/// as a `Codable` value. A plugin build writes it into its manifest beside the `PackageManifest`;
/// the host reads it without loading anything.
///
/// The resolution is the engine's own: `MLXServeEngine.register()` charges exactly
/// `persistentBytes` and reserves exactly `peakTransientBytes` for a configuration whose lane
/// reads that way (`MemoryGovernor` and this type pick the base footprint through the one
/// function, `RequirementsManifest.chosenFootprint(quant:budgetBytes:)`).
public struct ResolvedLane: Sendable, Codable, Equatable {

    /// Where one resolved number came from.
    public enum Source: String, Sendable, Codable, Equatable {
        /// A `FootprintConfigured` hint on the configuration — the lane's own measurement.
        case hint
        /// The `QuantFootprint` whose quant matches the configuration's `QuantConfigured` quant.
        case quantMatch
        /// No quant match: the largest declared footprint that fits the budget, else the smallest
        /// (the engine's survey rule). With no budget given, the largest declared.
        case largestThatFits
        /// Nothing declared it.
        case undeclared
    }

    /// Who puts the lane's weights on disk.
    public enum Materialization: String, Sendable, Codable, Equatable {
        /// The engine downloads `weightSources` before `load()` (contract 1.24). A host can do
        /// it ahead of time with `MLXServeEngine.materialize(package:)`.
        case engine
        /// The package downloads inside its own `load()` (`SelfMaterializing`), so the weights
        /// cannot be fetched without loading the model.
        case package
        /// Every weight ships in the binary (`BundledWeightSourcing` only); nothing to download.
        case bundled
        /// The configuration declares no sources (`WeightSourcing` not adopted): the package
        /// fetches through its own cache and the engine cannot preview or pre-fetch it.
        case undeclared
    }

    /// The contract version the exporting build defined.
    public let contractVersion: SemanticVersion
    /// The configuration's selected quant (`QuantConfigured`), when it declares one.
    public let quant: Quant?
    /// The quant of the `QuantFootprint` the resolution started from, when one was chosen.
    public let footprintQuant: Quant?
    /// Persistent weight residency the engine charges while the package is loaded.
    public let persistentBytes: UInt64
    public let persistentSource: Source
    /// The transient activation peak the engine reserves for a run (one reserve across residents).
    public let peakTransientBytes: UInt64
    public let peakTransientSource: Source
    /// How the transient moves with a run-time workload, and the ceiling the engine refuses past.
    public let activationScaling: ActivationScaling?
    /// Expected weight bytes read from disk per run (the projected-I/O advisory's input).
    public let expectedWeightReadBytesPerRun: UInt64?
    /// The weights volume's crash floor in bytes/second, when this variant declares one.
    public let minSustainedReadBytesPerSecond: UInt64?
    /// Who materializes the weights.
    public let materialization: Materialization
    /// Every network source the lane needs on a fresh machine (`WeightSourcing`; empty otherwise).
    public let weightSources: [WeightSource]
    /// Whether the configuration is `SelfMaterializing` (mirrors `materialization == .package`).
    public let selfMaterializing: Bool
    /// The capabilities this configuration backs: every surface whose `quantFloor` the selected
    /// quant meets (the engine's per-surface floor rule at `register()`).
    public let capabilities: [Capability]

    /// `persistentBytes + peakTransientBytes` — what one loaded, running instance needs.
    public var peakBytes: UInt64 { persistentBytes &+ peakTransientBytes }

    public init(contractVersion: SemanticVersion = ContractVersion.current,
                quant: Quant?, footprintQuant: Quant?,
                persistentBytes: UInt64, persistentSource: Source,
                peakTransientBytes: UInt64, peakTransientSource: Source,
                activationScaling: ActivationScaling?,
                expectedWeightReadBytesPerRun: UInt64?,
                minSustainedReadBytesPerSecond: UInt64?,
                materialization: Materialization,
                weightSources: [WeightSource],
                selfMaterializing: Bool,
                capabilities: [Capability]) {
        self.contractVersion = contractVersion
        self.quant = quant
        self.footprintQuant = footprintQuant
        self.persistentBytes = persistentBytes
        self.persistentSource = persistentSource
        self.peakTransientBytes = peakTransientBytes
        self.peakTransientSource = peakTransientSource
        self.activationScaling = activationScaling
        self.expectedWeightReadBytesPerRun = expectedWeightReadBytesPerRun
        self.minSustainedReadBytesPerSecond = minSustainedReadBytesPerSecond
        self.materialization = materialization
        self.weightSources = weightSources
        self.selfMaterializing = selfMaterializing
        self.capabilities = capabilities
    }

    /// Resolve a configuration against its package's manifest, the way `register()` does.
    ///
    /// - Parameter budgetBytes: the memory budget the "largest that fits" fallback measures
    ///   against. It matters only when the configuration declares no quant or none matches; `nil`
    ///   (a build that does not know the machine) takes the largest declared footprint, which
    ///   never under-reserves.
    public init(manifest: PackageManifest,
                configuration: any PackageConfiguration,
                budgetBytes: UInt64? = nil) {
        let quant = (configuration as? QuantConfigured)?.quant
        let hints = configuration as? FootprintConfigured
        let requirements = manifest.requirements
        let budget = budgetBytes ?? .max
        let chosen = requirements.chosenFootprint(quant: quant, budgetBytes: budget)
        let base: Source = chosen == nil
            ? .undeclared
            : (quant != nil && chosen?.quant == quant ? .quantMatch : .largestThatFits)

        let persistentHint = hints?.residentBytesHint
        let transientHint = hints?.peakActivationBytesHint
        let materialization: Materialization
        let sources = (configuration as? WeightSourcing)?.weightSources ?? []
        let selfMaterializing = configuration is SelfMaterializing
        if configuration is WeightSourcing {
            materialization = selfMaterializing ? .package : .engine
        } else if configuration is BundledWeightSourcing {
            materialization = .bundled
        } else {
            materialization = selfMaterializing ? .package : .undeclared
        }

        self.init(
            quant: quant,
            footprintQuant: chosen?.quant,
            persistentBytes: persistentHint ?? chosen?.residentBytes ?? 0,
            persistentSource: persistentHint != nil ? .hint : base,
            peakTransientBytes: transientHint ?? chosen?.peakActivationBytes ?? 0,
            peakTransientSource: transientHint != nil ? .hint : base,
            activationScaling: hints?.activationScalingHint ?? chosen?.activationScaling,
            expectedWeightReadBytesPerRun: hints?.expectedWeightReadBytesPerRunHint
                ?? chosen?.expectedWeightReadBytesPerRun,
            minSustainedReadBytesPerSecond: chosen?.minSustainedReadBytesPerSecond,
            materialization: materialization,
            weightSources: sources,
            selfMaterializing: selfMaterializing,
            capabilities: manifest.surfaces
                .filter { surface in
                    guard let floor = surface.quantFloor, let quant else { return true }
                    return quant.meets(floor: floor)
                }
                .map(\.capability))
    }
}

extension RequirementsManifest {
    /// The `QuantFootprint` a configuration's resolution starts from: the one matching `quant`,
    /// else the largest whose `residentBytes` fits `budgetBytes`, else the smallest. `nil` only
    /// when no footprint is declared. ONE function for the engine's governor and for
    /// `ResolvedLane`, so the charge and the export can never read two different footprints.
    public func chosenFootprint(quant: Quant?, budgetBytes: UInt64) -> QuantFootprint? {
        if let quant, let match = footprints.first(where: { $0.quant == quant }) {
            return match
        }
        let sorted = footprints.sorted { $0.residentBytes < $1.residentBytes }
        return sorted.last(where: { $0.residentBytes <= budgetBytes }) ?? sorted.first
    }
}
