import Foundation

// Typed adapters (LoRA) — contract 1.53.0, AB-A-0189 (L1 of AB-D-0155).
//
// Before this, an adapter rode free-form `metaData` in five incompatible package dialects, no
// manifest could say a surface took one, and every package fetched its own files from unpinned
// `resolve/main` URLs with no hash, no token and no consent, outside the engine's store and its
// memory accounting. The contract now carries the whole path:
//
//   • a request names adapters by id — `adapters: [AdapterRef]` on `T2IRequest`, `IEditRequest`,
//     `T2VRequest` and `VEditRequest` (`AdapterCarrying`);
//   • a surface declares what it accepts — `ToolDescriptor.adapters: AdapterSupport?`;
//   • the engine holds a catalog of `AdapterDescriptor`s, each pinned to `{repo, revision, file,
//     sha256}`, resolves the ids against it, materializes and hash-checks the files in its own
//     store, and hands the package `resolvedAdapters: [ResolvedAdapter]` — local, verified files
//     with the effective strength and the conditioning inputs in declared slot order;
//   • adapter bytes and a reference-conditioned adapter's activation multiplier are charged to
//     the run's admission reserve (`AdapterFootprint`).
//
// The registry FORMAT (titles, triggers, prompt templates, verification evidence) is L2's
// business; `AdapterDescriptor` is the subset the engine needs, and is `Codable` so a registry
// entry can embed or extend it.

// MARK: - Vocabulary

/// What an adapter needs besides its weights (contract 1.53.0). An open vocabulary, like `Mode`:
/// a later kind is a new constant, never a breaking enum case.
public struct AdapterKind: RawRepresentable, Sendable, Codable, Hashable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// A weight delta only: the adapter changes how the model renders, and needs no input.
    public static let plain: AdapterKind = "plain"
    /// In-context / reference-conditioned ("IC"): the adapter was trained against extra inputs —
    /// a pose skeleton, a reference sheet, a driving clip — fed through declared conditioning
    /// slots (`AdapterDescriptor.conditioning`). Its reference tokens lengthen the sequence, so it
    /// must declare `AdapterFootprint.activationMultiplier`.
    public static let referenceConditioned: AdapterKind = "ic"
}

/// The tensor-key dialect an adapter file is written in (contract 1.53.0). Every format is a
/// `.safetensors` file; what differs is how the delta is keyed and scaled. Open vocabulary: a
/// package lists the dialects its applicator matches, and a dialect not named here is a new
/// constant in that package's own namespace until a second package shares it.
public struct AdapterFormat: RawRepresentable, Sendable, Codable, Hashable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// diffusers / PEFT: `<module>.lora_A.weight` / `<module>.lora_B.weight`, usually under a
    /// `transformer.` or `diffusion_model.` prefix (LTX-2, Qwen-Image, FLUX.2 diffusers exports).
    public static let diffusersPEFT: AdapterFormat = "diffusers-peft"
    /// kohya / sd-scripts: `lora_down` / `lora_up` plus a per-module `alpha`.
    public static let kohya: AdapterFormat = "kohya"
    /// Black Forest Labs' fused layout: the attention projections' deltas stacked as one fused
    /// tensor per block (FLUX.2 Klein's native exports).
    public static let bflFused: AdapterFormat = "bfl-fused"
}

/// The media kind a conditioning slot takes.
public enum ConditioningMediaKind: String, Sendable, Codable, Hashable, CaseIterable {
    case image, video, audio
}

/// One conditioning input's media — a canonical artifact (contract 1.53.0). Switch with
/// `@unknown default`: a later kind is a new case.
public enum ConditioningMedia: Sendable, Equatable {
    case image(Image)
    case video(Video)
    case audio(Audio)

    public var kind: ConditioningMediaKind {
        switch self {
        case .image: .image
        case .video: .video
        case .audio: .audio
        }
    }
}

extension ConditioningMedia: Codable {
    private enum CodingKeys: String, CodingKey { case kind, image, video, audio }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ConditioningMediaKind.self, forKey: .kind) {
        case .image: self = .image(try container.decode(Image.self, forKey: .image))
        case .video: self = .video(try container.decode(Video.self, forKey: .video))
        case .audio: self = .audio(try container.decode(Audio.self, forKey: .audio))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .image(let image): try container.encode(image, forKey: .image)
        case .video(let video): try container.encode(video, forKey: .video)
        case .audio(let audio): try container.encode(audio, forKey: .audio)
        }
    }
}

/// One role-tagged conditioning input for a reference-conditioned adapter (contract 1.53.0) —
/// the `ConditioningInput` LTX's IC plan proposed (`ltx-2-mlx-swift/IC-LORA-PLAN.md` §3a).
///
/// The contract standardizes the envelope only: roles are strings the ADAPTER defines in its
/// declared slots ("pose", "reference_sheet", "dub_audio"), so a new adapter never needs a new
/// request field.
public struct ConditioningInput: Sendable, Codable, Equatable {
    /// The slot this input fills (`AdapterConditioningSlot.role`).
    public let role: String
    public let media: ConditioningMedia
    /// How strongly the reference conditions the run (LTX's reference strength); nil = the
    /// package's default. Distinct from the adapter's own `AdapterRef.strength`.
    public let strength: Double?

    public init(role: String, media: ConditioningMedia, strength: Double? = nil) {
        self.role = role
        self.media = media
        self.strength = strength
    }
}

// MARK: - Request side

/// One adapter a request asks for, by catalog id (contract 1.53.0).
///
/// Deliberately NOT a repo or a file: the id names an entry in the engine's adapter catalog
/// (`MLXServeEngine.registerAdapter`), which pins the bytes. A client can only ask for adapters
/// the host has curated, never for an arbitrary download (AB-D-0155: no client uploads).
public struct AdapterRef: Sendable, Codable, Equatable {
    /// The catalog id (`AdapterDescriptor.id`).
    public let id: String
    /// The adapter's strength (LoRA scale). nil = the descriptor's `defaultStrength`. The engine
    /// refuses a value outside the range the surface and the adapter both admit — never clamps.
    public let strength: Double?
    /// Role-tagged inputs for a reference-conditioned adapter, in any order: the engine orders
    /// them into the descriptor's slot order. Empty for a plain adapter (anything else is refused).
    public let conditioning: [ConditioningInput]

    public init(id: String, strength: Double? = nil, conditioning: [ConditioningInput] = []) {
        self.id = id
        self.strength = strength
        self.conditioning = conditioning
    }

    private enum CodingKeys: String, CodingKey { case id, strength, conditioning }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        strength = try container.decodeIfPresent(Double.self, forKey: .strength)
        conditioning = try container.decodeIfPresent([ConditioningInput].self, forKey: .conditioning) ?? []
    }
}

/// A request that can carry adapters (contract 1.53.0): `T2IRequest`, `IEditRequest`,
/// `T2VRequest`, `VEditRequest`.
///
/// `adapters` is what the caller asked for; `resolvedAdapters` is what the engine resolved, in
/// the same order, and is what a package reads. The engine ALWAYS re-stamps `resolvedAdapters`
/// before `run(_:)` (to `[]` when nothing was asked), so a value a caller set is never what a
/// package sees through the engine. A test that drives a package directly stamps it with
/// `resolving(_:)`.
public protocol AdapterCarrying: CapabilityRequest {
    var adapters: [AdapterRef] { get }
    var resolvedAdapters: [ResolvedAdapter] { get }
    /// This request with `resolvedAdapters` replaced.
    func resolving(_ resolved: [ResolvedAdapter]) -> Self
}

/// One adapter as the package receives it (contract 1.53.0): a local file the engine fetched at
/// the pinned revision and checked against its sha256, with everything the request and the
/// catalog said about it resolved.
public struct ResolvedAdapter: Sendable, Codable, Equatable {
    public let id: String
    public let kind: AdapterKind
    public let format: AdapterFormat
    /// The verified file, inside the engine's models root.
    public let fileURL: URL
    /// Where the bytes came from (pinned).
    public let source: AdapterSource
    /// The effective strength: the request's, or the descriptor's default — inside the admitted
    /// range either way.
    public let strength: Double
    /// The conditioning inputs in the descriptor's slot order (stable within a role). Empty for a
    /// plain adapter.
    public let conditioning: [ConditioningInput]
    /// What the engine charged for this adapter at admission.
    public let footprint: AdapterFootprint

    public init(id: String, kind: AdapterKind, format: AdapterFormat, fileURL: URL,
                source: AdapterSource, strength: Double, conditioning: [ConditioningInput] = [],
                footprint: AdapterFootprint) {
        self.id = id
        self.kind = kind
        self.format = format
        self.fileURL = fileURL
        self.source = source
        self.strength = strength
        self.conditioning = conditioning
        self.footprint = footprint
    }
}

/// A configuration whose package can only apply adapters when it is constructed (contract
/// 1.53.0) — the opt-in behind `AdapterSupport.Binding.loadTime`.
///
/// The engine stamps the run's resolved set onto `loadedAdapters` before construction, and when
/// a later run names a different set it waits for the package's in-flight runs, evicts it and
/// re-admits it with the new set. Detected by `as?` like `ModelStorable`; a `.loadTime` surface
/// whose configuration does not conform is refused before admission.
public protocol AdapterConfigured {
    var loadedAdapters: [ResolvedAdapter] { get set }
}

// MARK: - Catalog side

/// The pinned origin of one adapter file (contract 1.53.0). The engine fetches exactly this —
/// never `main` — and refuses bytes whose digest differs.
public struct AdapterSource: Sendable, Codable, Equatable, Hashable {
    /// Hugging Face repo id ("org/name").
    public let repo: String
    /// The full 40-character commit hash. A branch or tag name is refused at registration: it
    /// can move under the digest.
    public let revision: String
    /// The file's path inside the repo.
    public let file: String
    /// Lowercase hex SHA-256 of the file (the hub's LFS `oid`).
    public let sha256: String
    /// The file's size in bytes, when known — lets a preview size the download without the hub.
    public let bytes: UInt64?

    public init(repo: String, revision: String, file: String, sha256: String, bytes: UInt64? = nil) {
        self.repo = repo
        self.revision = revision
        self.file = file
        self.sha256 = sha256.lowercased()
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey { case repo, revision, file, sha256, bytes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(repo: try container.decode(String.self, forKey: .repo),
                  revision: try container.decode(String.self, forKey: .revision),
                  file: try container.decode(String.self, forKey: .file),
                  sha256: try container.decode(String.self, forKey: .sha256),
                  bytes: try container.decodeIfPresent(UInt64.self, forKey: .bytes))
    }

    /// `revision` is a full commit hash.
    public var isPinned: Bool { Self.isHex(revision, length: 40) }

    /// Everything wrong with this source, empty when it is fetchable as declared.
    public var validationProblems: [String] {
        var problems: [String] = []
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count != 2 || parts.contains(where: \.isEmpty) {
            problems.append("repo \"\(repo)\" is not org/name")
        }
        if !isPinned {
            problems.append("revision \"\(revision)\" is not a 40-character commit hash")
        }
        if !Self.isHex(sha256, length: 64) {
            problems.append("sha256 \"\(sha256)\" is not 64 hex characters")
        }
        let components = file.split(separator: "/", omittingEmptySubsequences: false)
        if file.isEmpty || file.hasPrefix("/") || components.contains(where: { $0 == ".." || $0.isEmpty }) {
            problems.append("file \"\(file)\" is not a relative path inside the repo")
        }
        return problems
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { $0.isHexDigit }
    }
}

/// An inclusive strength range (contract 1.53.0).
public struct AdapterStrengthRange: Sendable, Codable, Equatable, Hashable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    public var isWellFormed: Bool { min.isFinite && max.isFinite && min <= max }
    public func contains(_ value: Double) -> Bool { value >= min && value <= max }

    /// The overlap of two ranges, or nil when they do not meet.
    public func intersection(_ other: AdapterStrengthRange) -> AdapterStrengthRange? {
        let lower = Swift.max(min, other.min), upper = Swift.min(max, other.max)
        return lower <= upper ? AdapterStrengthRange(min: lower, max: upper) : nil
    }
}

/// One ordered conditioning slot a reference-conditioned adapter declares (contract 1.53.0).
/// The ARRAY order on the descriptor is the slot order, and it is load-bearing: Klein's
/// RefControl reads slot 1 as the pose skeleton and slot 2 as the subject.
public struct AdapterConditioningSlot: Sendable, Codable, Equatable {
    public let role: String
    public let media: ConditioningMediaKind
    public let required: Bool
    /// How many inputs this role takes (an image set), at least 1.
    public let maxCount: Int
    /// Help text for a picker.
    public let note: String?

    public init(role: String, media: ConditioningMediaKind, required: Bool = true, maxCount: Int = 1,
                note: String? = nil) {
        self.role = role
        self.media = media
        self.required = required
        self.maxCount = maxCount
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case role, media, required, maxCount, note }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        media = try container.decode(ConditioningMediaKind.self, forKey: .media)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount) ?? 1
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

/// What applying one adapter costs in memory (contract 1.53.0), charged to the run that applies
/// it — measured with the package that applies it, like every footprint.
public struct AdapterFootprint: Sendable, Codable, Equatable, Hashable {
    /// Bytes the adapter holds while applied (its delta tensors at the dtype the package keeps
    /// them). A per-request adapter adds them to the run's transient reserve; a load-time one to
    /// the package's persistent residency.
    public let residentBytes: UInt64
    /// How much the base model's activation peak grows when this adapter runs, ≥ 1. A plain
    /// adapter is 1. A reference-conditioned adapter appends reference tokens to the sequence —
    /// LTX IC roughly doubles it — and declares the measured factor. With several adapters the
    /// engine applies the largest.
    public let activationMultiplier: Double

    public init(residentBytes: UInt64, activationMultiplier: Double = 1) {
        self.residentBytes = residentBytes
        self.activationMultiplier = activationMultiplier
    }

    public var isWellFormed: Bool { activationMultiplier.isFinite && activationMultiplier >= 1 }
}

/// One curated adapter in the engine's catalog (contract 1.53.0) — what an `AdapterRef.id`
/// resolves to. The engine-facing subset of the L2 registry entry.
public struct AdapterDescriptor: Sendable, Codable, Equatable {
    /// Catalog id, unique per engine. Clients name adapters by it, so it also implies the base
    /// model (AB-D-0155): an id never stands for two files.
    public let id: String
    public let title: String?
    public let kind: AdapterKind
    public let format: AdapterFormat
    /// The base models this adapter fits, matched against `AdapterSupport.baseModel`.
    public let baseModels: [String]
    /// The surfaces it applies to (a Klein edit adapter is `[.imageEdit]`).
    public let capabilities: [Capability]
    public let source: AdapterSource
    /// The adapter's own licence. The engine classifies it against its `LicensePolicy` at
    /// registration, exactly as it does a package's weight licence.
    public let license: SPDXLicense
    public let defaultStrength: Double
    /// The range this adapter was validated over; nil = whatever the surface admits.
    public let strengthRange: AdapterStrengthRange?
    /// Ordered conditioning slots. Non-empty exactly when `kind` is `.referenceConditioned`.
    public let conditioning: [AdapterConditioningSlot]
    /// nil for a plain adapter means `residentBytes = source.bytes ?? 0` and no activation growth.
    /// A reference-conditioned adapter must declare one.
    public let footprint: AdapterFootprint?

    public init(id: String, title: String? = nil, kind: AdapterKind = .plain,
                format: AdapterFormat, baseModels: [String], capabilities: [Capability],
                source: AdapterSource, license: SPDXLicense, defaultStrength: Double = 1,
                strengthRange: AdapterStrengthRange? = nil,
                conditioning: [AdapterConditioningSlot] = [], footprint: AdapterFootprint? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.format = format
        self.baseModels = baseModels
        self.capabilities = capabilities
        self.source = source
        self.license = license
        self.defaultStrength = defaultStrength
        self.strengthRange = strengthRange
        self.conditioning = conditioning
        self.footprint = footprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, format, baseModels, capabilities, source, license, defaultStrength,
             strengthRange, conditioning, footprint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        kind = try container.decodeIfPresent(AdapterKind.self, forKey: .kind) ?? .plain
        format = try container.decode(AdapterFormat.self, forKey: .format)
        baseModels = try container.decode([String].self, forKey: .baseModels)
        capabilities = try container.decode([Capability].self, forKey: .capabilities)
        source = try container.decode(AdapterSource.self, forKey: .source)
        // A registry writes the identifier as a plain string; `SPDXLicense`'s own keyed form is
        // accepted too.
        if let identifier = try? container.decode(String.self, forKey: .license) {
            license = SPDXLicense(identifier)
        } else {
            license = try container.decode(SPDXLicense.self, forKey: .license)
        }
        defaultStrength = try container.decodeIfPresent(Double.self, forKey: .defaultStrength) ?? 1
        strengthRange = try container.decodeIfPresent(AdapterStrengthRange.self, forKey: .strengthRange)
        conditioning = try container.decodeIfPresent([AdapterConditioningSlot].self,
                                                     forKey: .conditioning) ?? []
        footprint = try container.decodeIfPresent(AdapterFootprint.self, forKey: .footprint)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(format, forKey: .format)
        try container.encode(baseModels, forKey: .baseModels)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(source, forKey: .source)
        try container.encode(license.identifier, forKey: .license)
        try container.encode(defaultStrength, forKey: .defaultStrength)
        try container.encodeIfPresent(strengthRange, forKey: .strengthRange)
        try container.encode(conditioning, forKey: .conditioning)
        try container.encodeIfPresent(footprint, forKey: .footprint)
    }

    /// The footprint the engine charges: the declared one, or the file's bytes with no
    /// activation growth.
    public var resolvedFootprint: AdapterFootprint {
        footprint ?? AdapterFootprint(residentBytes: source.bytes ?? 0)
    }

    public var isReferenceConditioned: Bool { kind == .referenceConditioned }

    /// Everything wrong with this descriptor, empty when the engine can register it. The ADP-4
    /// gate (`MLXServeConformance.AdapterConformance`) runs this over a whole registry.
    public var validationProblems: [String] {
        var problems = source.validationProblems
        if id.isEmpty { problems.append("empty id") }
        if baseModels.isEmpty || baseModels.contains(where: \.isEmpty) {
            problems.append("baseModels must name at least one non-empty base model")
        }
        let carrying = capabilities.filter(AdapterSupport.carryingCapabilities.contains)
        if capabilities.isEmpty || carrying.count != capabilities.count {
            problems.append("capabilities must be non-empty and each one an adapter-carrying "
                + "capability (\(AdapterSupport.carryingCapabilities.map(\.rawValue).sorted().joined(separator: ", ")))")
        }
        if let strengthRange {
            if !strengthRange.isWellFormed {
                problems.append("strengthRange \(strengthRange.min)…\(strengthRange.max) is not a finite, ordered range")
            } else if !strengthRange.contains(defaultStrength) {
                problems.append("defaultStrength \(defaultStrength) is outside its strengthRange")
            }
        }
        if !defaultStrength.isFinite { problems.append("defaultStrength is not finite") }
        if let footprint, !footprint.isWellFormed {
            problems.append("footprint.activationMultiplier must be finite and ≥ 1")
        }
        if isReferenceConditioned {
            if conditioning.isEmpty {
                problems.append("a reference-conditioned adapter declares no conditioning slots")
            }
            if footprint == nil {
                problems.append("a reference-conditioned adapter must declare its footprint "
                    + "(activationMultiplier): its reference tokens lengthen the sequence")
            }
        } else if !conditioning.isEmpty {
            problems.append("only a reference-conditioned adapter declares conditioning slots")
        }
        let roles = conditioning.map(\.role)
        if Set(roles).count != roles.count || roles.contains(where: \.isEmpty) {
            problems.append("conditioning roles must be non-empty and distinct")
        }
        if conditioning.contains(where: { $0.maxCount < 1 }) {
            problems.append("a conditioning slot's maxCount must be at least 1")
        }
        return problems
    }

    /// Order `inputs` into this descriptor's slot order (stable within a role), refusing an
    /// unknown role, the wrong media, too many inputs for a slot, or a missing required slot.
    /// Throws `PackageError.unsupportedRequestFeature` — the engine's pre-flight refusal, and a
    /// package driven directly can call it too.
    public func orderedConditioning(_ inputs: [ConditioningInput]) throws -> [ConditioningInput] {
        guard isReferenceConditioned else {
            if inputs.isEmpty { return [] }
            throw PackageError.unsupportedRequestFeature(
                "adapter \"\(id)\" conditioning — a plain adapter takes no conditioning inputs")
        }
        for input in inputs {
            guard let slot = conditioning.first(where: { $0.role == input.role }) else {
                throw PackageError.unsupportedRequestFeature(
                    "adapter \"\(id)\" conditioning role \"\(input.role)\" — not one of its slots ("
                        + conditioning.map(\.role).joined(separator: ", ") + ")")
            }
            guard slot.media == input.media.kind else {
                throw PackageError.unsupportedRequestFeature(
                    "adapter \"\(id)\" conditioning role \"\(input.role)\" takes \(slot.media.rawValue), "
                        + "not \(input.media.kind.rawValue)")
            }
        }
        var ordered: [ConditioningInput] = []
        for slot in conditioning {
            let filled = inputs.filter { $0.role == slot.role }
            if filled.isEmpty, slot.required {
                throw PackageError.unsupportedRequestFeature(
                    "adapter \"\(id)\" conditioning role \"\(slot.role)\" is required")
            }
            if filled.count > slot.maxCount {
                throw PackageError.unsupportedRequestFeature(
                    "adapter \"\(id)\" conditioning role \"\(slot.role)\" takes at most "
                        + "\(slot.maxCount), got \(filled.count)")
            }
            ordered.append(contentsOf: filled)
        }
        return ordered
    }
}

// MARK: - Manifest side

/// What a surface accepts in the way of adapters (contract 1.53.0), on
/// `ToolDescriptor.adapters`. nil = the surface takes none, which is every pre-1.53 conformer, and
/// a request naming adapters there is refused before admission.
///
/// On the descriptor rather than in `SurfaceControls`, like `rawImageFormats`: it is routing-time
/// for four capabilities alike, and a consumer must pick a package that takes adapters BEFORE
/// it runs one.
public struct AdapterSupport: Sendable, Codable, Equatable {
    /// When the package can change its adapters.
    public enum Binding: String, Sendable, Codable, Hashable {
        /// Applied and removed around each run — any request can name any admitted set.
        case perRequest
        /// Fused when the model is built. The configuration must adopt `AdapterConfigured`; a run
        /// naming a different set than the resident one costs an evict + reload, which the
        /// engine performs.
        case loadTime
    }

    /// The capabilities a request can carry adapters on.
    public static let carryingCapabilities: Set<Capability> = [.textToImage, .imageEdit,
                                                               .textToVideo, .videoEdit]

    /// The base model adapters must name (`AdapterDescriptor.baseModels`), e.g. "flux2-klein-4b".
    /// The same string across a package's surfaces when they share one checkpoint.
    public let baseModel: String
    /// The key dialects the package's applicator matches.
    public let formats: [AdapterFormat]
    /// The kinds it can run; `.referenceConditioned` only where the conditioning path exists.
    public let kinds: [AdapterKind]
    /// The most adapters one request may stack, at least 1.
    public let maxCount: Int
    /// The strengths the package applies faithfully.
    public let strengthRange: AdapterStrengthRange
    /// The base quants adapters may be applied at; nil = every quant the package ships. A
    /// configuration at another quant refuses adapters (when it exposes its quant —
    /// `QuantConfigured`).
    public let quants: [Quant]?
    public let binding: Binding

    public init(baseModel: String, formats: [AdapterFormat], kinds: [AdapterKind] = [.plain],
                maxCount: Int = 1, strengthRange: AdapterStrengthRange = AdapterStrengthRange(min: 0, max: 2),
                quants: [Quant]? = nil, binding: Binding = .perRequest) {
        self.baseModel = baseModel
        self.formats = formats
        self.kinds = kinds
        self.maxCount = maxCount
        self.strengthRange = strengthRange
        self.quants = quants
        self.binding = binding
    }

    /// Everything wrong with this declaration, empty when it is coherent (ADP-1).
    public var validationProblems: [String] {
        var problems: [String] = []
        if baseModel.isEmpty { problems.append("empty baseModel") }
        if formats.isEmpty { problems.append("no formats") }
        if kinds.isEmpty { problems.append("no kinds") }
        if maxCount < 1 { problems.append("maxCount \(maxCount) < 1") }
        if !strengthRange.isWellFormed {
            problems.append("strengthRange \(strengthRange.min)…\(strengthRange.max) is not a finite, ordered range")
        }
        if let quants, quants.isEmpty { problems.append("quants is empty (use nil for any quant)") }
        return problems
    }

    /// Why `descriptor` does not fit this surface, or nil when it does: the capability, a base
    /// model, the kind and the format must all match.
    public func mismatch(_ descriptor: AdapterDescriptor, capability: Capability) -> String? {
        if !descriptor.capabilities.contains(capability) {
            return "applies to " + descriptor.capabilities.map(\.rawValue).joined(separator: ", ")
                + ", not \(capability.rawValue)"
        }
        if !descriptor.baseModels.contains(baseModel) {
            return "fits " + descriptor.baseModels.joined(separator: ", ")
                + ", not this surface's base model \(baseModel)"
        }
        if !kinds.contains(descriptor.kind) {
            return "is a \(descriptor.kind) adapter; this surface runs "
                + kinds.map(\.rawValue).joined(separator: ", ")
        }
        if !formats.contains(descriptor.format) {
            return "is in the \(descriptor.format) dialect; this surface reads "
                + formats.map(\.rawValue).joined(separator: ", ")
        }
        return nil
    }

    /// One adapter of a validated request, before materialization.
    public struct Plan: Sendable, Equatable {
        public let descriptor: AdapterDescriptor
        public let strength: Double
        public let conditioning: [ConditioningInput]
    }

    /// Validate a request's adapters against this surface and a catalog — the engine's
    /// pre-flight, callable by a host that wants to refuse before submitting. Throws
    /// `PackageError.unsupportedRequestFeature` naming the first problem: too many adapters, a
    /// repeated or unknown id, an adapter that does not fit, a base quant outside `quants`, a
    /// strength outside the admitted range, or conditioning that does not fill the slots.
    ///
    /// - Parameter quant: the configuration's quant, nil when it does not expose one (the quant
    ///   check is then skipped: unknowable is not the same as outside).
    public func plan(_ refs: [AdapterRef], capability: Capability, quant: Quant?,
                     lookup: (String) -> AdapterDescriptor?) throws -> [Plan] {
        guard !refs.isEmpty else { return [] }
        if refs.count > maxCount {
            throw PackageError.unsupportedRequestFeature(
                "adapters — \(refs.count) requested, the surface stacks at most \(maxCount) "
                    + "(AdapterSupport.maxCount)")
        }
        let ids = refs.map(\.id)
        if Set(ids).count != ids.count {
            throw PackageError.unsupportedRequestFeature("adapters — an adapter id is repeated")
        }
        if let quants, let quant, !quants.contains(quant) {
            throw PackageError.unsupportedRequestFeature(
                "adapters — this configuration runs \(quant.rawValue); the surface applies adapters "
                    + "only at " + quants.map(\.rawValue).joined(separator: ", ")
                    + " (AdapterSupport.quants)")
        }
        return try refs.map { ref in
            guard let descriptor = lookup(ref.id) else {
                throw PackageError.unsupportedRequestFeature(
                    "adapter \"\(ref.id)\" — not in the engine's adapter catalog")
            }
            if let why = mismatch(descriptor, capability: capability) {
                throw PackageError.unsupportedRequestFeature("adapter \"\(ref.id)\" \(why)")
            }
            let range = descriptor.strengthRange.flatMap { strengthRange.intersection($0) }
                ?? (descriptor.strengthRange == nil ? strengthRange : nil)
            let strength = ref.strength ?? descriptor.defaultStrength
            guard strength.isFinite, let range, range.contains(strength) else {
                throw PackageError.unsupportedRequestFeature(
                    "adapter \"\(ref.id)\" strength \(strength) — outside the admitted range "
                        + (range.map { "\($0.min)…\($0.max)" } ?? "(the surface's and the adapter's ranges do not meet)"))
            }
            return Plan(descriptor: descriptor, strength: strength,
                        conditioning: try descriptor.orderedConditioning(ref.conditioning))
        }
    }
}
