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

/// Emotion + duration controls a **`tts`** surface honors natively (contract 1.38.0, E12), and
/// since 1.49.0 the multi-speaker cast it renders in one take (`speakerTags`).
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
    /// The literal turn tags of a multi-speaker script, in speaker order (contract 1.49.0,
    /// AB-A-0136): `speakerTags[k]` marks the turns spoken by `TTSRequest.speakers[k]`. Dia2-2B
    /// declares `["[S1]", "[S2]"]`. Nil or empty = a single-voice surface, which is every pre-1.49
    /// conformer. A surface declares distinct, non-empty tags.
    ///
    /// Literal strings rather than a count plus a template, because scene models do not share a
    /// syntax and a planner writing the script needs the exact text the package splits turns on.
    /// The count is the routing fact (`maxSpeakers`), and one list carries both, so they cannot
    /// disagree. Optional, so descriptor JSON from 1.38–1.48 decodes unchanged.
    public let speakerTags: [String]?

    /// The most voices one request can carry on this surface: one per declared tag, at least 1.
    /// `MLXServeEngine.run` refuses a `TTSRequest` whose `speakers` outnumber it.
    public var maxSpeakers: Int { max(1, speakerTags?.count ?? 0) }

    public init(emotionModes: [EmotionMode] = [], supportsTargetDuration: Bool = false,
                speakerTags: [String]? = nil) {
        self.emotionModes = emotionModes
        self.supportsTargetDuration = supportsTargetDuration
        self.speakerTags = speakerTags
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
    /// The a2v declaration for `T2VRequest.initAudio` (contract 1.40.0, AB-A-0023).
    case textToVideo(T2VControls)
    /// The native-alpha declaration for `T2IRequest.background` (contract 1.48.0).
    case textToImage(T2IControls)
    /// What a speech-edit surface can do: operations, label vocabularies, the longest take
    /// (contract 1.50.0, AB-A-0137). Required on every `speechEdit` surface.
    case speechEdit(SpeechEditControls)
    /// Image input on chat turns (`ChatMessage.images`) — contract 1.54.0, AB-A-0190.
    case llm(LLMControls)
    /// What a music surface honors beyond the core: the declared features, planning and edit modes,
    /// vocal languages, the longest song (contract 1.56.0, AB-A-0201 / AB-A-0202). Required on every
    /// `music` surface.
    case music(MusicControls)
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
    /// `ttsControls` / `sttControls` / `t2vControls` / `t2iControls` / `speechEditControls`
    /// accessors below (and, since 1.54.0, `llmControls`; since 1.56.0, `musicControls`).
    public let controls: SurfaceControls?
    /// The raw `Image` formats this surface reads AND returns in kind, beyond the png/jpeg every image
    /// surface takes (contract 1.52.0, additive). A descriptor-level member, like `quantFloor`, because
    /// it is routing-time and not one capability's: a consumer decides BEFORE the run whether to send
    /// 16 bits, and every image capability will grow the same declaration.
    ///
    /// Listing `.rawRGBA16` means the surface keeps 16 bits end to end: a `.rawRGBA16` image comes back
    /// `.rawRGBA16`, and a 16-bit PNG comes back a 16-bit PNG. ENGINE-ENFORCED: a request carrying a
    /// `.rawRGBA16` image on a surface that does not list it is refused with
    /// `PackageError.unsupportedRequestFeature` before admission.
    ///
    /// `nil` = undeclared, which is every pre-1.52 conformer: png/jpeg, plus `.rawBGRA8` where the
    /// consumer knows the package mirrors it (that 1.9.0 convention stays undeclared and unenforced).
    public let rawImageFormats: [Image.Format]?
    /// The adapters (LoRA) this surface accepts (contract 1.53.0, additive). A descriptor-level
    /// member like `rawImageFormats`: routing-time for every adapter-carrying capability alike
    /// (`AdapterSupport.carryingCapabilities`). ENGINE-ENFORCED: a request naming adapters on a
    /// surface that declares none, or adapters this declaration does not admit, is refused with
    /// `PackageError.unsupportedRequestFeature` before admission. `nil` = none, which is every
    /// pre-1.53 conformer. Declare it with `declaring(adapters:)`, which also advertises the
    /// `adapters` parameter.
    public let adapters: AdapterSupport?

    public init(name: String,
                capability: Capability,
                summary: String,
                parameters: [ParameterSchema] = [],
                supportedModes: [Mode] = [],
                quantFloor: Quant? = nil,
                streaming: StreamGranularity? = nil,
                controls: SurfaceControls? = nil,
                rawImageFormats: [Image.Format]? = nil,
                adapters: AdapterSupport? = nil) {
        self.name = name
        self.capability = capability
        self.summary = summary
        self.parameters = parameters
        self.supportedModes = supportedModes
        self.quantFloor = quantFloor
        self.streaming = streaming
        self.controls = controls
        self.rawImageFormats = rawImageFormats
        self.adapters = adapters
    }

    /// This descriptor, declaring `rawImageFormats` (contract 1.52.0). Lets any capability's canonical
    /// factory declare a raw boundary without a parameter per factory:
    /// `ImageUpscaleContract.descriptor(name:summary:).declaring(rawImageFormats: [.rawBGRA8, .rawRGBA16])`.
    public func declaring(rawImageFormats formats: [Image.Format]) -> ToolDescriptor {
        ToolDescriptor(name: name, capability: capability, summary: summary, parameters: parameters,
                       supportedModes: supportedModes, quantFloor: quantFloor, streaming: streaming,
                       controls: controls, rawImageFormats: formats, adapters: adapters)
    }

    /// This descriptor, declaring the adapters it accepts (contract 1.53.0), and advertising the
    /// `adapters` parameter — only declared surfaces offer it, so a planner is never handed a knob
    /// the engine would refuse:
    /// `T2IContract.descriptor(name:summary:).declaring(adapters: AdapterSupport(baseModel: "flux2-klein-4b", formats: [.bflFused, .diffusersPEFT]))`.
    public func declaring(adapters support: AdapterSupport) -> ToolDescriptor {
        var parameters = parameters
        if !parameters.contains(where: { $0.name == "adapters" }) {
            parameters.append(ParameterSchema(
                name: "adapters", kind: .array, required: false,
                summary: "Adapters (LoRA) by catalog id, each {id, strength?, conditioning?}; up to "
                    + "\(support.maxCount), strength \(support.strengthRange.min)…\(support.strengthRange.max)."))
        }
        return ToolDescriptor(name: name, capability: capability, summary: summary,
                              parameters: parameters, supportedModes: supportedModes,
                              quantFloor: quantFloor, streaming: streaming, controls: controls,
                              rawImageFormats: rawImageFormats, adapters: support)
    }

    /// Whether a declared `adapters` block sits on a capability that can carry adapters. `false` is
    /// a package bug (ADP-1).
    public var adaptersMatchCapability: Bool {
        adapters == nil || AdapterSupport.carryingCapabilities.contains(capability)
    }

    /// Whether this surface declares the 16-bit boundary (`rawImageFormats` lists `.rawRGBA16`).
    public var acceptsRawRGBA16: Bool { rawImageFormats?.contains(.rawRGBA16) == true }
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

    /// The `textToVideo` control declaration, or nil when this surface declares none
    /// (contract 1.40.0). `t2vControls?.supportsInitAudio == true` is what admits
    /// `T2VRequest.initAudio`.
    public var t2vControls: T2VControls? {
        if case .textToVideo(let declared) = controls { return declared }
        return nil
    }

    /// The `textToImage` control declaration, or nil when this surface declares none
    /// (contract 1.48.0). `t2iControls?.supportsTransparentBackground == true` is what admits
    /// `T2IRequest.background == .transparent`.
    public var t2iControls: T2IControls? {
        if case .textToImage(let declared) = controls { return declared }
        return nil
    }

    /// The `speechEdit` control declaration, or nil when this surface declares none (contract
    /// 1.50.0). A `SpeechEditRequest` is admitted only for an operation it lists, and for an
    /// emotion / style label inside a declared vocabulary.
    public var speechEditControls: SpeechEditControls? {
        if case .speechEdit(let declared) = controls { return declared }
        return nil
    }

    /// The `llm` control declaration, or nil when this surface declares none (contract 1.54.0).
    /// `llmControls?.acceptsImages == true` is what admits `ChatMessage.images`.
    public var llmControls: LLMControls? {
        if case .llm(let declared) = controls { return declared }
        return nil
    }

    /// The `music` control declaration, or nil when this surface declares none (contract 1.56.0). A
    /// `MusicRequest` is admitted only for the features it declares (`MusicControls.refusal(for:)`).
    public var musicControls: MusicControls? {
        if case .music(let declared) = controls { return declared }
        return nil
    }

    /// Whether a declared controls block matches this surface's capability. `false` is a package
    /// bug: the block would describe a surface the descriptor does not name.
    public var controlsMatchCapability: Bool {
        switch controls {
        case nil: return true
        case .tts: return capability == .tts
        case .stt: return capability == .stt
        case .textToVideo: return capability == .textToVideo
        case .textToImage: return capability == .textToImage
        case .speechEdit: return capability == .speechEdit
        case .llm: return capability == .llm
        case .music: return capability == .music
        }
    }
}
