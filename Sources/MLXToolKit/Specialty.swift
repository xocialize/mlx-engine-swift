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

    // tts control-plane ranking (E12 lane): native per-request control levers a TTS model
    // carries, so the orchestrator/dub route can prefer native control over post-hoc shims
    // (instruct-string emotion, WSOLA time-stretch fit).
    /// Native emotion control decoupled from speaker identity (e.g. IndexTTS2's
    /// categorical-8 / vector emotion plane).
    public static let emotionControl: Specialty = "emotionControl"
    /// Native output-duration control (e.g. IndexTTS2's length-regulator target length).
    public static let durationControl: Specialty = "durationControl"

    // tts voice-cloning / architecture ranking: the selection axes that let the
    // orchestrator/dub route prefer a cloner or a streaming-first engine.
    /// Zero-shot voice cloning from a short reference clip — no per-speaker fine-tune
    /// (the axis IndexTTS2, VoxCPM2, Qwen3-TTS, and Gepard-1.0 all share).
    public static let voiceClone: Specialty = "voiceClone"
    /// Streaming-first, low-latency architecture that emits audio incrementally
    /// rather than only after whole-utterance synthesis (e.g. Gepard-1.0).
    public static let realtimeStreaming: Specialty = "realtimeStreaming"

    // Style / domain ranking.
    /// Anime-domain specialization (e.g. the AnimeGen T2V fine-tune). Promoted to core from a
    /// package-side extension — exactly the drift `registeredVocabulary` exists to catch.
    public static let anime: Specialty = "anime"

    // 3D lane ranking. NOTE the kebab-case raw values: these terms shipped in package manifests
    // before the vocabulary was registered, and the raw value is what a declaration carries, so
    // they are grandfathered as-is. New terms use camelCase (see `registeredVocabulary`).
    /// Generates 3D geometry (e.g. TRELLIS.2).
    public static let threeDGeneration: Specialty = "3d-generation"
    /// Produces a skeleton + skin weights for a mesh (e.g. SkinTokens `auto`).
    public static let meshRigging: Specialty = "mesh-rigging"
    /// Rigging specialized to humanoid characters (e.g. SkinTokens `skinOnly` on a VRM).
    public static let characterRigging: Specialty = "character-rigging"
}

// MARK: - Vocabulary governance (C6)

extension Specialty {

    /// The **registered vocabulary** — every term the fleet declares today.
    ///
    /// `Specialty` is `ExpressibleByStringLiteral`, so without this the namespace drifts
    /// (`"line-art"` vs `"lineart"` vs `"lineArt"` all "work" and none of them match each other,
    /// which quietly breaks Model-Manager ranking). This mirrors `SPDXLicense.permissiveAllowlist`:
    /// a core-owned, additive set that makes the vocabulary reviewable.
    ///
    /// **Enforcement is warn-only** at `MLXServeEngine.register()`: an unregistered specialty logs
    /// a warning naming the term, and registration proceeds. Hard rejection would break unknown
    /// third-party conformers with no deprecation window.
    ///
    /// **This stays warn-only — decided 2026-07-26, the question is closed.** It was carried as a
    /// "next-major decision" for a while; contract 1.28.0 settled the house rule by moving C7/C8 the
    /// other way (license blocker → advisory), on the reasoning that a runtime refusal turns a
    /// *declaration* problem into a load failure inside the package everything depends on. That
    /// applies with more force here: a mistyped specialty degrades Model-Manager **ranking**, which is
    /// strictly less consequential than serving weights under an unreviewed license. Rejecting here
    /// while merely reporting there would leave the engine strictest about its least important
    /// declaration. The rule is uniform: **the engine reports declaration problems, it does not refuse
    /// to run.** If the drift ever needs more teeth, make it more *visible* (surface
    /// `engine.unregisteredSpecialties` in the host UI, as `licenseAdvisories` can be) — not fatal.
    ///
    /// **Convention for new terms:** camelCase (`poseDriven`, `voiceClone`). The kebab-case 3D
    /// terms are grandfathered — their raw values are already declared in shipped manifests.
    /// Adding a term = adding a `static let` above and an entry here, in the same change.
    public static let registeredVocabulary: Set<Specialty> = [
        .general, .coder, .researcher, .companion,
        .poseless, .poseDriven,
        .emotionControl, .durationControl, .voiceClone, .realtimeStreaming,
        .anime,
        .threeDGeneration, .meshRigging, .characterRigging,
    ]

    /// Whether this term is in the registered vocabulary.
    public var isRegistered: Bool { Self.registeredVocabulary.contains(self) }
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
