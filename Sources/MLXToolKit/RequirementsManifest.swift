/// Compute backends a model needs. Maps onto the engine's MemoryPool placement.
public enum Backend: String, Sendable, Codable, Hashable, CaseIterable {
    case metalGPU
    case coreMLANE
    case coreMLCPU
    case coreMLGPU
}

/// Quantization levels a model may ship.
public enum Quant: String, Sendable, Codable, Hashable, CaseIterable {
    case fp32
    case fp16
    case bf16
    case int8
    case int4
    case mxfp4
}

/// Apple-silicon chip-tier floor a model requires.
public enum ChipTier: String, Sendable, Codable, Comparable, CaseIterable {
    case base
    case pro
    case max
    case ultra

    private var order: Int { ChipTier.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: ChipTier, rhs: ChipTier) -> Bool { lhs.order < rhs.order }
}

/// OS floor. macOS today; iOS is a future consideration and will be added additively.
public struct OSRequirement: Sendable, Codable, Equatable {
    public let minMacOS: SemanticVersion?
    public init(minMacOS: SemanticVersion? = nil) { self.minMacOS = minMacOS }
}

/// Resident memory footprint for one quantization.
public struct QuantFootprint: Sendable, Codable, Equatable {
    public let quant: Quant
    public let residentBytes: UInt64
    public init(quant: Quant, residentBytes: UInt64) {
        self.quant = quant
        self.residentBytes = residentBytes
    }
}

/// What a model costs to run — consumed by the Model Manager to match a DeviceProfile (C10).
/// This is cost-to-run, deliberately distinct from the tool *contract* (C2: what it can do).
public struct RequirementsManifest: Sendable, Codable, Equatable {
    public let footprints: [QuantFootprint]
    public let requiredBackends: Set<Backend>
    public let os: OSRequirement
    public let chipFloor: ChipTier?

    public init(footprints: [QuantFootprint],
                requiredBackends: Set<Backend>,
                os: OSRequirement = OSRequirement(),
                chipFloor: ChipTier? = nil) {
        self.footprints = footprints
        self.requiredBackends = requiredBackends
        self.os = os
        self.chipFloor = chipFloor
    }
}
