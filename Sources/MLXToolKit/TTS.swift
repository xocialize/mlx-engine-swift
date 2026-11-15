import Foundation

/// Voice selection for TTS.
///
/// Voice is *canonical* — every TTS model has the concept — so it lives in the schema, not
/// in `metaData` (C5). How a package realizes the voice (its strengths, prosody engine,
/// internal voice ids) is its own business and may use `metaData` for those extras.
public struct VoiceSelector: Sendable, Codable, Equatable {
    public enum Selection: Sendable, Codable, Equatable {
        case named(String)         // a package-known voice id
        case referenceAudio(Audio) // clone from a reference clip (canonical Audio artifact)
        case auto                  // let the package choose its default
    }

    public let selection: Selection
    public init(_ selection: Selection = .auto) { self.selection = selection }
}

/// One speaker's voice in a multi-speaker script (contract 1.49.0, AB-A-0136).
///
/// The pair a one-voice request carries as `TTSRequest.voice` + `referenceTranscript`, made
/// repeatable. A scene renderer (Dia2-2B) conditions EACH speaker on its own voice prefix, and a
/// scene only holds its voices when every speaker is prefixed: E23 measured 0.80 cosine to the
/// references with both speakers prefixed, 0.44 with speaker 1 alone.
///
/// Reference word timings are deliberately NOT a member. Dia2 is their only consumer, so they ride
/// its `metaData` (`referenceWords` / `speaker2Words`) until a second adopter needs them — the
/// promotion rule `TTSRequest.referenceTranscript` records.
public struct TTSSpeakerVoice: Sendable, Codable, Equatable {
    public let voice: VoiceSelector
    /// Transcript of this speaker's `.referenceAudio` clip. Ignored unless `voice` is
    /// `.referenceAudio` — the `TTSRequest.referenceTranscript` rule, per speaker.
    public let referenceTranscript: String?

    public init(voice: VoiceSelector = VoiceSelector(), referenceTranscript: String? = nil) {
        self.voice = voice
        self.referenceTranscript = referenceTranscript
    }
}

/// How an emotion is handed to a TTS surface (contract 1.38.0, E12).
///
/// Deliberately shaped like `VoiceSelector.Selection`, its sibling in this file, because the
/// problem is the same one: a single canonical field several genuinely different mechanisms have
/// to fit through, one of them a canonical `Audio` artifact. The case a value carries maps 1:1
/// onto the `TTSControls.EmotionMode` a package declares (see `mode`), so a consumer checks
/// supportability without learning a second vocabulary.
///
/// **The contract carries the plane, not the vocabulary.** `categorical` is an open `String`
/// because the emotion CATEGORIES are the audio packages' to agree on (E12's 9→8 map is their
/// work), governed the way `Mode`/`Specialty`/`RunPhase` are. A closed enum here would freeze one
/// model family's taxonomy into the contract, and the first model with a ninth emotion would
/// need a contract revision to say so.
public enum TTSEmotion: Sendable, Codable, Equatable {
    /// A named category — "happy", "angry". Vocabulary is package-defined and open.
    case categorical(String)
    /// A numeric emotion vector; dimensionality and axis meaning are model-defined (IndexTTS2's
    /// emotion head, or a valence/arousal/dominance triple from an annotation stage).
    case vector([Float])
    /// Copy the emotion from a clip, decoupled from timbre — this is NOT voice cloning
    /// (`VoiceSelector.referenceAudio` is that, and the two compose: clone A, emote like B).
    case referenceAudio(Audio)
    /// Natural-language direction ("sound exhausted") — Qwen3-TTS `instruct`.
    case textDescription(String)

    /// The declaration this value requires a surface to have made.
    public var mode: TTSControls.EmotionMode {
        switch self {
        case .categorical: .categorical
        case .vector: .vector
        case .referenceAudio: .referenceAudio
        case .textDescription: .textDescription
        }
    }
}

extension Mode {
    // Example TTS modes a package may honor. Modes are open/extensible.
    public static let expressive: Mode = "expressive"
    public static let neutral: Mode = "neutral"
}

/// Canonical TTS request. Canonical output is always `.wav` (see `TTSResponse`).
public struct TTSRequest: CapabilityRequest, Codable {
    public static var capability: Capability { .tts }

    public let text: String
    public let voice: VoiceSelector
    /// Transcript of the `.referenceAudio` clip, for ICL-grade cloning. Canonical because
    /// every ICL-style cloning TTS (Qwen3-TTS, VoxCPM2, CosyVoice, VibeVoice) conditions on
    /// (reference audio, reference text) as a pair — promoted from `metaData` when the second
    /// package needed it (contract 1.1.0). Ignored unless `voice` is `.referenceAudio`;
    /// packages without an ICL path may ignore it (their cloning quality tier is theirs).
    public let referenceTranscript: String?
    /// Voices for speakers 2…N of a multi-speaker script (contract 1.49.0, AB-A-0136). Speaker 1
    /// stays `voice` + `referenceTranscript`, so every pre-1.49 request is a one-speaker request,
    /// unchanged. Element k is the speaker whose turns carry the surface's
    /// `ttsControls?.speakerTags[k + 1]`; read the whole cast, in order, as `speakers`.
    ///
    /// Promoted from `metaData` on the rule `referenceTranscript` records. Dia2-2B
    /// (`mlx-dia2-tts-swift`) carried speaker 2 there first (`speaker2Audio` /
    /// `speaker2Transcript`); ML[X] Audio Studio's Dub scene path is the second adopter, and would
    /// otherwise have to hardcode which engine reads which key — the table 1.38.0 retired.
    ///
    /// DECLARATION-GATED, unlike `ImageTo3DRequest.additionalViews`, because an ignored voice is
    /// wrong output rather than degraded output: the scene comes back in one voice, or with speaker
    /// 2 in a voice nobody asked for, and nothing in the `.wav` says so. `MLXServeEngine.run`
    /// refuses more voices than the surface declares (`TTSControls.maxSpeakers`) with
    /// `PackageError.unsupportedRequestFeature`, before admission. Nil or empty asks for nothing
    /// and is never refused.
    public let additionalSpeakers: [TTSSpeakerVoice]?
    /// Optional emotion steering (contract 1.38.0, E12). Promoted from `metaData` on exactly the
    /// rule `referenceTranscript` records above — a second adopter arrived. IndexTTS2 shipped the
    /// first realization via `metaData` 2026-07-09; ML[X] Audio Studio's Dub section became the
    /// second 2026-09-01, and the untyped path had made it hardcode which engine reads which key.
    ///
    /// Send only a mode the surface DECLARES (`ToolDescriptor.ttsControls?.emotionModes`).
    /// `MLXServeEngine.run` refuses an undeclared one with
    /// `PackageError.unsupportedRequestFeature` before admission — silently ignoring a canonical
    /// request field is a contract violation (the rule 1.16.0 set for `responseFormat`).
    public let emotion: TTSEmotion?
    /// Optional target output length in seconds — synthesize to fit a cue window (contract
    /// 1.38.0, E12). Only for a surface declaring `TTSControls.supportsTargetDuration`; a
    /// consumer routed to one that does not should time-stretch the result instead, which is the
    /// decision the flag exists to make routable. **Not a hard guarantee**: a package fits as
    /// closely as its native duration control allows, and the returned `.wav` is the truth.
    public let targetDuration: TimeInterval?
    /// Ask for word (or word + phoneme) timings with the audio (contract 1.65.0, AB-A-0289). Nil
    /// means none were asked for. Every pre-1.65 request is nil.
    ///
    /// The field is opt-in rather than always-on because some producers have a real cost: a forced
    /// aligner run after synthesis (`TTSTimingDeclaration.Source.aligned`) adds latency to every
    /// sentence. DECLARATION-GATED: `MLXServeEngine.run` / `stream` refuse it before admission with
    /// `PackageError.unsupportedRequestFeature` on a surface whose `ttsControls?.timings` is nil,
    /// and refuse `.phonemes` on one that declares no `phonemeAlphabet`. When the field is set on a
    /// declaring surface, the package MUST return `TTSResponse.timings` at the asked detail. When
    /// the field is nil, a package MAY still return timings it gets for free, but a caller cannot
    /// rely on that.
    public let timingDetail: TTSTimingDetail?
    public let mode: Mode?
    public let metaData: MetaData

    public init(text: String,
                voice: VoiceSelector = VoiceSelector(),
                referenceTranscript: String? = nil,
                additionalSpeakers: [TTSSpeakerVoice]? = nil,
                emotion: TTSEmotion? = nil,
                targetDuration: TimeInterval? = nil,
                timingDetail: TTSTimingDetail? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.text = text
        self.voice = voice
        self.referenceTranscript = referenceTranscript
        self.additionalSpeakers = additionalSpeakers
        self.emotion = emotion
        self.targetDuration = targetDuration
        self.timingDetail = timingDetail
        self.mode = mode
        self.metaData = metaData
    }

    /// A multi-speaker request with the cast in script order (contract 1.49.0): `speakers[0]`
    /// becomes `voice` + `referenceTranscript` and the rest `additionalSpeakers`, so the two
    /// spellings build the same value. An empty cast is a default-voice request.
    public init(text: String,
                speakers: [TTSSpeakerVoice],
                emotion: TTSEmotion? = nil,
                targetDuration: TimeInterval? = nil,
                timingDetail: TTSTimingDetail? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        let first = speakers.first ?? TTSSpeakerVoice()
        self.init(text: text,
                  voice: first.voice,
                  referenceTranscript: first.referenceTranscript,
                  additionalSpeakers: speakers.count > 1 ? Array(speakers.dropFirst()) : nil,
                  emotion: emotion,
                  targetDuration: targetDuration,
                  timingDetail: timingDetail,
                  mode: mode,
                  metaData: metaData)
    }

    /// The whole cast in script order: `voice` + `referenceTranscript` first — derived, so the two
    /// can never disagree — then `additionalSpeakers`. Never empty; a one-voice request has one.
    public var speakers: [TTSSpeakerVoice] {
        [TTSSpeakerVoice(voice: voice, referenceTranscript: referenceTranscript)]
            + (additionalSpeakers ?? [])
    }
}

/// Canonical TTS response. Always returns `.wav` audio in serialized round-trip form.
public struct TTSResponse: CapabilityResponse, Codable {
    public let audio: Audio
    /// When each word (and phoneme) is spoken in `audio`, in seconds from its first sample
    /// (contract 1.65.0, AB-A-0289). Nil means not reported, which is every pre-1.65 package. It is
    /// non-nil whenever the request set `timingDetail` on a surface that declares
    /// `TTSControls.timings`. It may also be non-nil unasked, when the package gets timings for free.
    /// For a streamed run, this is the concatenation of every chunk's `timings` (STR-8).
    public let timings: TTSTimings?
    public init(audio: Audio, timings: TTSTimings? = nil) {
        self.audio = audio
        self.timings = timings
    }
}

/// One PCM slice of an in-flight TTS synthesis (contract 1.25.0, ENGINE-NEEDS N2).
///
/// Deliberately NOT an `Audio` artifact: a per-chunk .wav container would be waste and a lie
/// (no valid standalone header semantics). The canonical artifact contract is untouched — the
/// aggregated response a streaming run also returns is still always `.wav`. Run-timing
/// OBSERVABILITY (latency, real-time factor) still rides `RunProgress`, not this type. Speech
/// timing, meaning when each word is spoken, is DATA, and since 1.65.0 it rides `timings` below.
public struct TTSStreamChunk: Sendable, Codable, Equatable {
    /// Mono PCM samples, normalized to [-1, 1].
    public let samples: [Float]
    public let sampleRate: Int
    /// 0-based chunk ordinal; strictly monotonic, no gaps.
    public let index: Int
    /// Exactly one chunk carries `true`, and it is the last.
    public let isFinal: Bool
    /// The word (and phoneme) timings that became FINAL with this chunk (contract 1.65.0,
    /// AB-A-0289). Nil or empty means none did. Times are measured from the first sample of chunk 0,
    /// the same origin as `TTSResponse.timings`, and never from this chunk's start.
    ///
    /// Each timing rides exactly one chunk. It may describe audio that went out in an EARLIER
    /// chunk: a reading-position tracker (ZONOS3's LACI) knows a word's end only once the next word
    /// starts. It may also describe audio that a LATER chunk will carry: an aligner that runs on a
    /// sentence before its audio goes out. A consumer schedules timings against its own playback
    /// clock, not against chunk boundaries. Concatenating every chunk's `words` (and `phonemes`)
    /// in order gives the aggregated response's `timings` exactly (STR-8). The final chunk may
    /// carry the trailing words. `phonemeAlphabet` is repeated on every chunk that carries phonemes.
    public let timings: TTSTimings?

    public init(samples: [Float], sampleRate: Int, index: Int, isFinal: Bool,
                timings: TTSTimings? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.index = index
        self.isFinal = isFinal
        self.timings = timings
    }
}

// MARK: - Speech timings (contract 1.65.0, AB-A-0289)

/// When one word is spoken in a TTS response (contract 1.65.0).
///
/// It uses the same three fields as `STTSegment`, so a forced aligner's output and a TTS
/// package's native timings are the same shape on both sides of the contract.
public struct TTSWordTiming: Sendable, Codable, Equatable {
    /// The word as the package aligned it. This may be the normalised spoken form, for example
    /// "twenty" for "20". It need not be a substring of `TTSRequest.text`.
    public let text: String
    /// Seconds from the first sample of the response audio. For a stream, that is the first sample
    /// of chunk 0.
    public let start: TimeInterval
    /// Seconds. A producer that knows only starts (Dia2) uses the next word's start minus this
    /// one's, and the last word runs to the end of speech.
    public let duration: TimeInterval

    public init(text: String, start: TimeInterval, duration: TimeInterval) {
        self.text = text
        self.start = start
        self.duration = duration
    }

    /// `start + duration`.
    public var end: TimeInterval { start + duration }
}

/// When one phoneme is spoken in a TTS response (contract 1.65.0). Its `symbol` is written in
/// the `TTSTimings.phonemeAlphabet` it travels with.
public struct TTSPhonemeTiming: Sendable, Codable, Equatable {
    public let symbol: String
    /// Seconds, from the same origin as `TTSWordTiming.start`.
    public let start: TimeInterval
    public let duration: TimeInterval
    /// The word this phoneme belongs to: an index into the RESPONSE-WIDE `words` array, which on a
    /// stream is the concatenation of every chunk's words, not this chunk's. Nil means not
    /// attributed (punctuation pauses, or a producer that does not track it).
    public let wordIndex: Int?

    public init(symbol: String, start: TimeInterval, duration: TimeInterval,
                wordIndex: Int? = nil) {
        self.symbol = symbol
        self.start = start
        self.duration = duration
        self.wordIndex = wordIndex
    }

    /// `start + duration`.
    public var end: TimeInterval { start + duration }
}

/// The phoneme inventory a `TTSPhonemeTiming.symbol` is written in (contract 1.65.0).
///
/// It is an OPEN tag, for the reason `Mode` is one: the alphabets belong to the G2P front-ends
/// (misaki, espeak-ng, CMUdict). A closed enum would make the next front-end wait for a contract
/// revision. A consumer that maps phonemes to visemes needs the tag to choose its table.
public struct TTSPhonemeAlphabet: RawRepresentable, Sendable, Codable, Equatable, Hashable,
                                  ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// The International Phonetic Alphabet, one IPA segment per symbol.
    public static let ipa: TTSPhonemeAlphabet = "ipa"
    /// misaki's phoneme set (Kokoro's G2P): IPA-based, with misaki's own diphthong letters.
    public static let misaki: TTSPhonemeAlphabet = "misaki"
    /// espeak-ng phoneme mnemonics.
    public static let espeak: TTSPhonemeAlphabet = "espeak"
    /// ARPAbet (CMUdict), stress digits allowed.
    public static let arpabet: TTSPhonemeAlphabet = "arpabet"
}

/// The speech timings of a TTS response, or of one stream chunk (contract 1.65.0, AB-A-0289).
///
/// It is grouped rather than spread across two optional arrays, because the phonemes are
/// meaningless without the alphabet they are written in. Keeping the three together means a
/// response carries all of them or none.
public struct TTSTimings: Sendable, Codable, Equatable {
    /// In spoken order. `start` never decreases.
    public let words: [TTSWordTiming]
    /// In spoken order. Nil means no phonemes: they were not asked for, or the surface provides none.
    public let phonemes: [TTSPhonemeTiming]?
    /// The alphabet `phonemes` are written in. It is required whenever `phonemes` is non-nil
    /// (`shapeProblem` refuses phonemes without one).
    public let phonemeAlphabet: TTSPhonemeAlphabet?

    public init(words: [TTSWordTiming], phonemes: [TTSPhonemeTiming]? = nil,
                phonemeAlphabet: TTSPhonemeAlphabet? = nil) {
        self.words = words
        self.phonemes = phonemes
        self.phonemeAlphabet = phonemeAlphabet
    }

    /// Nil when the timings are well-formed, otherwise the first problem found, in words. Checks:
    /// every number is finite, starts are ≥ 0, durations are ≥ 0, starts never decrease, phonemes
    /// carry an alphabet, and `wordIndex` is ≥ 0.
    ///
    /// `wordIndex` is not checked against `words.count`, because on a chunk it indexes the
    /// response-wide list. `StreamingConformance.checkTimingParity` (STR-8) checks that on the
    /// aggregate, and so does a package's suite on a batch response.
    public var shapeProblem: String? {
        func spanProblem(_ what: String, _ i: Int, _ start: TimeInterval,
                         _ duration: TimeInterval) -> String? {
            guard start.isFinite, duration.isFinite else { return "\(what)[\(i)]: non-finite time" }
            guard start >= 0 else { return "\(what)[\(i)]: negative start \(start)" }
            guard duration >= 0 else { return "\(what)[\(i)]: negative duration \(duration)" }
            return nil
        }
        var last = -TimeInterval.infinity
        for (i, w) in words.enumerated() {
            if let p = spanProblem("words", i, w.start, w.duration) { return p }
            guard w.start >= last else { return "words[\(i)]: start \(w.start) before the previous word's" }
            last = w.start
        }
        guard let phonemes else { return nil }
        guard phonemeAlphabet != nil else { return "phonemes without a phonemeAlphabet" }
        last = -TimeInterval.infinity
        for (i, p) in phonemes.enumerated() {
            if let problem = spanProblem("phonemes", i, p.start, p.duration) { return problem }
            guard p.start >= last else {
                return "phonemes[\(i)]: start \(p.start) before the previous phoneme's"
            }
            last = p.start
            if let w = p.wordIndex, w < 0 { return "phonemes[\(i)]: negative wordIndex \(w)" }
        }
        return nil
    }

    /// Joins chunk timings in stream order into the response-wide timings: the words and phonemes
    /// concatenated, and the alphabet taken from the first chunk that names one. Returns nil when
    /// no chunk carried any timing. A package aggregating its own stream can build
    /// `TTSResponse.timings` with this.
    public static func concatenating(_ parts: [TTSTimings?]) -> TTSTimings? {
        let present = parts.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        let words = present.flatMap(\.words)
        let phonemeParts = present.compactMap(\.phonemes)
        return TTSTimings(words: words,
                          phonemes: phonemeParts.isEmpty ? nil : phonemeParts.flatMap { $0 },
                          phonemeAlphabet: present.lazy.compactMap(\.phonemeAlphabet).first)
    }
}

/// How much timing a `TTSRequest` asks for (contract 1.65.0).
public enum TTSTimingDetail: String, Sendable, Codable, Equatable {
    /// Word timings.
    case words
    /// Word timings AND phoneme timings. Needs a surface that declares a `phonemeAlphabet`.
    case phonemes
}

/// What a TTS surface declares about the timings it returns (contract 1.65.0, AB-A-0289).
/// Read it as `ToolDescriptor.ttsControls?.timings`. Non-nil means word timings are provided.
public struct TTSTimingDeclaration: Sendable, Codable, Equatable {
    /// Where the timings come from. A router weighs latency and accuracy on this.
    public enum Source: String, Sendable, Codable, Equatable {
        /// From the model's own decode at no extra pass: a duration predictor (Kokoro), native word
        /// starts (Dia2), or an attention reading-position probe (ZONOS3 LACI).
        case native
        /// From a forced aligner run on the synthesized audio against the known text (Qwen3-
        /// ForcedAligner, FuseAlign). This costs added latency per sentence.
        case aligned
    }

    public let source: Source
    /// The alphabet phoneme timings are written in. Nil means this surface provides words only, and
    /// the engine refuses `TTSTimingDetail.phonemes` on it.
    public let phonemeAlphabet: TTSPhonemeAlphabet?
    /// The time grid word boundaries fall on, in seconds, when the producer has one (LACI 0.067
    /// at 15 Hz frames, Dia2 0.08, FuseAlign 0.001). This is the grid, NOT a measured accuracy
    /// against real onsets. Accuracy belongs in the package's receipts. Nil means not stated.
    public let wordResolution: TimeInterval?
    /// Timings arrive on stream chunks as they become final (`TTSStreamChunk.timings`). False means
    /// only the aggregated response carries them, which a lip-sync consumer that needs them during
    /// playback has to route around. This has no meaning on a surface that does not stream.
    public let streamed: Bool

    public init(source: Source, phonemeAlphabet: TTSPhonemeAlphabet? = nil,
                wordResolution: TimeInterval? = nil, streamed: Bool = false) {
        self.source = source
        self.phonemeAlphabet = phonemeAlphabet
        self.wordResolution = wordResolution
        self.streamed = streamed
    }

    /// Whether this declaration covers a requested detail. `.words` is always covered, and
    /// `.phonemes` only with an alphabet.
    public func covers(_ detail: TTSTimingDetail) -> Bool {
        switch detail {
        case .words: true
        case .phonemes: phonemeAlphabet != nil
        }
    }
}

/// The canonical descriptor shape for a TTS tool. A package fills in `name`/`summary` and
/// may extend `supportedModes`; the parameter schema is the canonical TTS surface.
public enum TTSContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = [],
                                  streaming: StreamGranularity? = nil,
                                  controls: TTSControls? = nil) -> ToolDescriptor {
        var parameters = [
            ParameterSchema(name: "text", kind: .string, required: true,
                            summary: "The text to speak."),
            ParameterSchema(name: "voice", kind: .object, required: false,
                            summary: "Canonical voice selection (named / referenceAudio / auto)."),
            ParameterSchema(name: "referenceTranscript", kind: .string, required: false,
                            summary: "Transcript of the referenceAudio clip (ICL-grade cloning)."),
        ]
        // The E12 controls appear on the surface only when the package DECLARES them, so a
        // planner is never offered a knob that is ignored (the `supportsStrength` precedent,
        // 1.30.0). One source of truth: the schema entries are derived from the declaration, so
        // the advertised parameters and `ttsControls` cannot drift apart.
        if let controls, !controls.emotionModes.isEmpty {
            parameters.append(ParameterSchema(
                name: "emotion", kind: .object, required: false,
                summary: "Emotion steering; modes honored: "
                    + controls.emotionModes.map(\.rawValue).joined(separator: " / ") + "."))
        }
        if controls?.supportsTargetDuration == true {
            parameters.append(ParameterSchema(
                name: "targetDuration", kind: .number, required: false,
                summary: "Target output length in seconds (native duration control)."))
        }
        // Contract 1.65.0: the timing knob appears only on a surface that declares timings.
        if let timings = controls?.timings {
            parameters.append(ParameterSchema(
                name: "timingDetail", kind: .string, required: false,
                summary: "Return speech timings with the audio: "
                    + (timings.phonemeAlphabet.map { "words / phonemes (\($0.rawValue))" } ?? "words")
                    + "; seconds from the start of the response audio."))
        }
        // Contract 1.49.0: only a multi-speaker surface is offered the extra voices, and the
        // planner is told the exact turn tags to write.
        if let controls, controls.maxSpeakers > 1 {
            parameters.append(ParameterSchema(
                name: "additionalSpeakers", kind: .array, required: false,
                summary: "Voices for the speakers after the first, in script order, each "
                    + "{voice, referenceTranscript}; speaker 1 is voice + referenceTranscript. "
                    + "Up to \(controls.maxSpeakers) speakers, tagged "
                    + (controls.speakerTags ?? []).joined(separator: " / ") + "."))
        }
        return ToolDescriptor(
            name: name,
            capability: .tts,
            summary: summary,
            parameters: parameters,
            supportedModes: modes,
            streaming: streaming,
            controls: controls.map(SurfaceControls.tts)
        )
    }
}
