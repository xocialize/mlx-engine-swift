/// A minimal, introspectable parameter schema so a tool client can describe a surface without
/// reverse-engineering it (C11).
///
/// **Deliberately an MCP-*like* subset, not JSON Schema** (decided 2026-07-22; C11 asserts
/// introspectability, not wire compatibility). Missing versus JSON Schema: value constraints
/// (`minimum`/`maximum`/`enum`/`default`), `properties`/`items` for the `object`/`array` kinds, and
/// a declared JSON encoding for the binary kinds (`image`/`audio`/`video`/`mesh`). Closing that gap
/// is **purely additive** — optional fields on this type plus a serializer — so it is left to
/// **integration time**, when a real non-LLM MCP consumer exists to settle the binary-encoding
/// convention rather than us guessing it. See `EngineeringDocs/MLXEngineDocs/
/// mcp-wire-fidelity-spike.md` for the per-surface gap list and ordering.
public struct ParameterSchema: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case string
        case integer
        case number
        case boolean
        case image
        case audio
        case video
        case object
        case array
        /// A 3D mesh input (GLB bytes). First used by `meshRig` (contract 1.19.0) — the first
        /// capability whose INPUT is a mesh (`imageTo3D` only OUTPUTs one, from an image input).
        case mesh
    }

    public let name: String
    public let kind: Kind
    public let required: Bool
    public let summary: String?

    public init(name: String, kind: Kind, required: Bool, summary: String? = nil) {
        self.name = name
        self.kind = kind
        self.required = required
        self.summary = summary
    }
}

/// What a surface can stream mid-run (contract 1.25.0, additive — the `quantFloor` precedent).
///
/// An enum, not a Bool: granularity is the axis that generalizes (future `.token` for LLM
/// surfaces, `.frame` for video) without another field. `nil` on the descriptor = batch-only,
/// which is every pre-1.25 conformer.
public enum StreamGranularity: String, Sendable, Codable {
    /// PCM audio chunks (`TTSStreamChunk`) via the `StreamEmitting` opt-in.
    case audioChunk
}

/// Emotion + duration controls a **`tts`** surface honors natively (contract 1.38.0, E12).
///
/// The promotion trigger E12 set for itself is met: the plane "pends a 2nd adopter"
/// (`mlxengine-audio/Docs/ENHANCEMENTS.md` § E12); IndexTTS2 shipped the first realization
/// through `metaData` 2026-07-09 and ML[X] Audio Studio's Dub section became the second
/// 2026-09-01 (AB-A-0049 → AB-A-0064). Without a declaration a consumer hardcodes a per-engine
/// routing table (`TTSEngine.supportsNativeDuration`) that goes stale with every new package —
/// it asks the descriptor instead. **Subsumes** the E6 speaker/emotion-catalog ask.
///
/// The contract carries the PLANE and does not legislate the vocabulary: which categorical
/// labels exist is the audio packages' business (`TTSEmotion.categorical` is an open `String`),
/// the same governance `Mode`/`Specialty`/`RunPhase` use.
public struct TTSControls: Sendable, Codable, Equatable {
    /// How a package can be *told* an emotion. A package declares every mode it honors.
    public enum EmotionMode: String, Sendable, Codable {
        /// A named category ("happy") — IndexTTS2's 8-way head, VoxCPM2's inline `(emotion)` tags.
        case categorical
        /// A numeric emotion vector; dimensionality and axis meaning are model-defined.
        case vector
        /// Copy the emotion from a clip, decoupled from timbre (IndexTTS2).
        case referenceAudio
        /// Natural-language direction (Qwen3-TTS `instruct`).
        case textDescription
    }

    /// Emotion modes this surface honors. Empty = emotion is not steerable here.
    public let emotionModes: [EmotionMode]
    /// Whether the surface synthesizes to a requested output length **natively**, as opposed to a
    /// consumer time-stretching afterwards (AudioPolishKit E8 v2). Routing turns on exactly that
    /// difference, which is why it is a declaration and not something a caller discovers by
    /// measuring the returned audio.
    public let supportsTargetDuration: Bool

    public init(emotionModes: [EmotionMode] = [], supportsTargetDuration: Bool = false) {
        self.emotionModes = emotionModes
        self.supportsTargetDuration = supportsTargetDuration
    }
}

/// What an **`stt`** surface offers beyond a plain transcript (contract 1.38.0).
///
/// Both members answer a question a consumer must settle BEFORE it runs, and neither is
/// answerable from a response: `STTSegment.speaker == nil` reads identically for "one person
/// spoke" and "this model does not diarize", and an ignored `context` is invisible.
public struct STTControls: Sendable, Codable, Equatable {
    /// The surface attributes spans to speakers — `STTSegment.speaker` is populated when the
    /// audio carries more than one (speaker-attributed ASR: VibeVoice-ASR; or a
    /// diarize-then-transcribe pairing). `false` = a single-stream transcriber, where `speaker`
    /// is always nil and that says nothing about the audio.
    public let attributesSpeakers: Bool
    /// The surface honors `STTRequest.context` (hotword / recognition biasing). Drives whether
    /// the descriptor advertises the parameter at all — a planner is never offered a knob that is
    /// ignored (the `ImageRestoreContract.descriptor(supportsStrength:)` precedent, 1.30.0).
    public let supportsContextBiasing: Bool
    /// The assembly discipline of this surface's LIVE transcription sessions, or `nil` when the
    /// surface is one-shot only — which is every pre-1.39 conformer (contract 1.39.0).
    ///
    /// Non-nil ⇔ the package conforms to `LiveTranscribing` (LIV-1 checks both directions).
    /// It declares two things at once: that live sessions exist here at all — the advertisement
    /// half of the `as?`-detected opt-in — and how a consumer assembles their chunks.
    ///
    /// It lives here rather than as a `StreamGranularity` case because that enum's invariant is
    /// "non-nil requires `StreamEmitting`" (what STR-1 asserts), and a live surface conforms to
    /// `LiveTranscribing` instead; and rather than as a bare `ToolDescriptor` member because an
    /// assembly discipline is as `stt`-specific as `attributesSpeakers` is. Adding a defaulted
    /// member is additive; adding a case to a public enum is not.
    ///
    /// Deliberately NOT joined here by `maxBufferedSeconds` (a session property — nobody routes
    /// on buffer depth) or by watermark availability (readable from any chunk, and the governing
    /// rule excludes anything learnable from a response).
    public let liveDiscipline: STTStreamDiscipline?

    public init(attributesSpeakers: Bool = false, supportsContextBiasing: Bool = false,
                liveDiscipline: STTStreamDiscipline? = nil) {
        self.attributesSpeakers = attributesSpeakers
        self.supportsContextBiasing = supportsContextBiasing
        self.liveDiscipline = liveDiscipline
    }
}

/// A per-capability block of **routing-time** declarations, carried by ONE optional field so the
/// shared descriptor does not accumulate a member per capability (contract 1.38.0).
///
/// **The governing rule**, recorded here because this is where that slope starts: a capability
/// earns a case only when a consumer must choose a package *before* running it. `quantFloor`
/// (1.23.0) and `streaming` (1.25.0) sit on the descriptor for precisely that reason. Anything a
/// caller can learn from the response does not belong here, and anything that steers a single run
/// is a request field, not a declaration.
///
/// The case must match the surface's `capability` (`ToolDescriptor.controlsMatchCapability`); a
/// `tts` block on an `stt` surface tells a consumer nothing true. Adding a case is additive —
/// consumers switch with `@unknown default`, the tolerance C12 already requires of `Capability`.
public enum SurfaceControls: Sendable, Codable, Equatable {
    case tts(TTSControls)
    case stt(STTControls)
}

/// Self-description a package publishes so the registry — and any out-of-process tool client, such
/// as an external MCP bridge app — can expose the surface as a discrete, introspectable,
/// intent-named tool (capability-as-tool).
///
/// **Tool exposure is deliberately NOT an engine component** (decided 2026-07-26). This type plus
/// `MLXServeEngine.registeredCapabilities` / `packages(for:)` / `manifest(for:)` / `run(_:package:)`
/// is the complete seam a bridge needs; it is `Codable`, so a client owns its own wire format. The
/// engine coordinates models, it does not serve protocols.
public struct ToolDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let capability: Capability
    public let summary: String
    public let parameters: [ParameterSchema]
    public let supportedModes: [Mode]
    /// Minimum quantization this **surface** is usable at (contract 1.23.0, additive).
    ///
    /// Quant gating is otherwise per-package, but a model can be int4-fine for analysis and
    /// int4-bad for generation — the same weights, different quality floors per surface. Declaring
    /// a floor here lets a configuration below it stop backing *this* capability while still
    /// backing the package's other surfaces (the engine's `register` skips it and
    /// `admissibility(for:configuration:capability:)` reports
    /// `.quantBelowSurfaceFloor`). `nil` = no per-surface constraint, which is every existing
    /// conformer.
    public let quantFloor: Quant?
    /// Mid-run streaming this surface offers (contract 1.25.0, additive). Non-nil requires the
    /// package to conform to `StreamEmitting` (STR-1 coherence). `nil` = batch-only = every
    /// existing conformer. NOTE: inert on the MCP wire in V1 (no streaming transport — see
    /// mcp-wire-fidelity-spike.md).
    public let streaming: StreamGranularity?
    /// Per-capability **routing-time** declarations (contract 1.38.0, additive). `nil` = this
    /// surface declares none, which is every pre-1.38 conformer. Read it through the
    /// `ttsControls` / `sttControls` accessors below.
    public let controls: SurfaceControls?

    public init(name: String,
                capability: Capability,
                summary: String,
                parameters: [ParameterSchema] = [],
                supportedModes: [Mode] = [],
                quantFloor: Quant? = nil,
                streaming: StreamGranularity? = nil,
                controls: SurfaceControls? = nil) {
        self.name = name
        self.capability = capability
        self.summary = summary
        self.parameters = parameters
        self.supportedModes = supportedModes
        self.quantFloor = quantFloor
        self.streaming = streaming
        self.controls = controls
    }
}

extension ToolDescriptor {
    /// The `tts` control declaration, or nil when this surface declares none (contract 1.38.0).
    public var ttsControls: TTSControls? {
        if case .tts(let declared) = controls { return declared }
        return nil
    }

    /// The `stt` control declaration, or nil when this surface declares none (contract 1.38.0).
    public var sttControls: STTControls? {
        if case .stt(let declared) = controls { return declared }
        return nil
    }

    /// Whether a declared controls block matches this surface's capability. `false` is a package
    /// bug: the block would describe a surface the descriptor does not name.
    public var controlsMatchCapability: Bool {
        switch controls {
        case nil: return true
        case .tts: return capability == .tts
        case .stt: return capability == .stt
        }
    }
}
