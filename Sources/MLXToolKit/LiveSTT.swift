//
//  LiveSTT.swift
//  MLXToolKit
//
//  The live-transcription plane (contract 1.39.0, companion N2) — designed in 1.38.0
//  (AB-D-0069) and held until a second implementation existed to test it against.
//
//  Read this file next to `Streaming.swift`. They are siblings in role and NOT variants of one
//  another: `StreamEmitting` streams OUTPUT from a complete input, inside one `@InferenceActor`
//  run; this plane streams output from an input that DOES NOT EXIST YET at call time, which is
//  a session, not a run. A microphone waited on inside `runStream` would hold the fleet's
//  serialized inference for as long as someone keeps talking.
//

import Foundation

/// How a consumer assembles a live session's chunks into a transcript. **Declared** on the
/// surface (`STTControls.liveDiscipline`), never inferred per chunk: guess wrong and you either
/// duplicate the transcript or drop half of it, and nothing in a chunk distinguishes the two
/// cases.
public enum STTStreamDiscipline: String, Sendable, Codable {
    /// Each chunk carries the whole transcript decoded so far — the consumer **replaces** what
    /// it is holding. First realization: Nemotron 3.5 ASR (cumulative RNN-T hypothesis).
    case cumulative
    /// Each chunk carries only text new since its predecessor — the consumer **appends**.
    /// First realization: VibeVoice-ASR-Streaming (per-chunk committed text).
    ///
    /// **Concatenated verbatim.** The package emits whatever leading separator the join needs;
    /// a consumer never inserts one. Any other rule makes the discipline unusable mechanically,
    /// because whether two chunks want a space between them is a fact about the model's
    /// tokenization that only the package knows.
    case incremental
}

extension STTStreamDiscipline {
    /// Assemble a session's chunks into one transcript — the discipline's semantics, executable.
    ///
    /// This is the batch form (a test, a "what do I have so far", a completed session). A live UI
    /// applies the same rule incrementally: `.cumulative` replaces its buffer with each chunk's
    /// `text`, `.incremental` appends it.
    public func assemble(_ chunks: [STTStreamChunk]) -> String {
        switch self {
        case .cumulative: return chunks.last?.text ?? ""
        case .incremental: return chunks.map(\.text).joined()
        }
    }
}

/// What became of the samples handed to `STTSession.push`.
///
/// Three cases, not the two AB-D-0069 specified. `.ended` exists because an `AVAudioEngine` tap
/// delivers one or two more buffers after `finish()` returns — a race ML[X] Audio Studio has
/// already paid for once (AB-T-0104's `pendingStop` fix) — and answering `.accepted` there would
/// be a lie about audio that was dropped. It is not a failure; it is the honest answer.
///
/// Switch with a `default` (C12's tolerance).
public enum PushOutcome: Sendable, Equatable {
    /// Copied into the session's input buffer. The only outcome that transcribes.
    case accepted
    /// The input buffer is full at `STTSession.maxBufferedSeconds` — **these samples were
    /// dropped** and the transcript will have a hole. The caller is producing audio faster than
    /// the model consumes it; the honest responses are to warn, to degrade, or to stop.
    case overrun
    /// The samples did not arrive at `STTSession.expectedSampleRate` and this session does not
    /// resample — **dropped**. A caller-side bug, reported rather than papered over: transcribing
    /// 48 kHz samples as 16 kHz produces confident nonsense, and nothing downstream can tell.
    case unsupportedSampleRate
    /// `finish()` or `cancel()` has already run, or the session failed — dropped, expected,
    /// not an error.
    case ended
}

/// One update from a live transcription session (contract 1.39.0).
///
/// **Partial-vs-final is a watermark, not a Bool.** `isFinal` marks the end of the SESSION, not
/// the settledness of the text; `committedThrough` is what a caption UI needs — everything after
/// it may still change, everything before it will not.
public struct STTStreamChunk: Sendable, Codable, Equatable {
    /// The transcript this chunk delivers — the whole thing so far under
    /// `.cumulative`, only the new text under `.incremental`. Which one is the surface's
    /// declared `STTControls.liveDiscipline`, and it is not inferrable from here.
    ///
    /// Under `.incremental` this is concatenated VERBATIM with its predecessors, so the package
    /// carries any leading separator; see `STTStreamDiscipline.assemble(_:)`.
    public let text: String
    /// Timestamped spans covering `text`, in order; carries `speaker` when the surface declares
    /// `STTControls.attributesSpeakers`. May be empty for models without timing output.
    public let segments: [STTSegment]
    /// The BCP-47 locale the model detected (or was told); nil when it does not report one.
    public let detectedLanguage: String?
    /// Seconds of audio the model has consumed. **The only honest progress axis** when the input
    /// has no known length — a percentage would need a total that does not exist. Non-decreasing
    /// across a session.
    public let processedSeconds: Double
    /// Audio time before which the transcript will **not** be revised. For a cache-aware model
    /// with a provisional tail, `processedSeconds - rightContextSeconds`; for a model that
    /// commits every chunk (and for an append-only greedy decoder), `processedSeconds`.
    ///
    /// `nil` = the package makes no commitment guarantee — and **nil-ness is constant for the
    /// lifetime of a session** (LIV-4). A package that commits, commits from chunk 0, so a
    /// consumer decides once how to render rather than per chunk.
    public let committedThrough: TimeInterval?
    /// 0-based ordinal; strictly monotonic, no gaps (STR-4's rule, transposed).
    public let index: Int
    /// Set on exactly one chunk, the last, and only by `finish()`. A cancelled session emits no
    /// final chunk.
    public let isFinal: Bool

    public init(text: String,
                segments: [STTSegment] = [],
                detectedLanguage: String? = nil,
                processedSeconds: Double,
                committedThrough: TimeInterval? = nil,
                index: Int,
                isFinal: Bool) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.processedSeconds = processedSeconds
        self.committedThrough = committedThrough
        self.index = index
        self.isFinal = isFinal
    }
}

/// What a live session is opened WITH — the session-scoped analogue of `STTRequest`, minus the
/// one thing a session cannot have: the audio.
///
/// It is a `CapabilityRequest` (`.stt`) on purpose. The engine's declared-control pre-flight
/// (`checkDeclaredControls`, 1.38.0) then refuses an undeclared `context` on the live path
/// through exactly the same code as `run(STTRequest)` — one enforcement site, so the two paths
/// cannot drift. `MLXServeEngine.run` and `.stream` refuse this type with a message naming
/// `transcribeLive(_:package:)`, so the conformance it buys costs no footgun.
public struct STTSessionRequest: CapabilityRequest {
    public static var capability: Capability { .stt }

    /// Optional BCP-47 language-locale hint (e.g. "en-US"). nil = model auto-detect.
    public let language: String?
    /// Optional recognition-biasing terms, as on `STTRequest` (contract 1.38.0). Fixed for the
    /// session — mid-session vocabulary changes are not a thing any candidate model supports,
    /// and inventing the surface before one does is how contracts rot.
    public let context: [String]?
    public let mode: Mode?
    public let metaData: MetaData

    public init(language: String? = nil, context: [String]? = nil,
                mode: Mode? = nil, metaData: MetaData = [:]) {
        self.language = language
        self.context = context
        self.mode = mode
        self.metaData = metaData
    }
}

/// One live transcription session: audio in by `push`, transcript out by `updates`.
///
/// ## The audio-thread rule, made structural
///
/// `push` is `nonisolated` and **must** be copy-only, non-blocking and MLX-free: every real
/// audio source is a callback on a real-time thread (an `AVAudioEngine` tap, a CoreAudio
/// IOProc), and running MLX there is the known failure. The implementation copies into a buffer
/// and returns; a driver task hops onto `@InferenceActor` per buffer, so the actor is free
/// between buffers and an hour-long session does not hold the fleet's serialized inference.
/// LIV-3 makes that testable rather than aspirational.
///
/// ## Back-pressure is explicit
///
/// The session declares `maxBufferedSeconds` and `push` reports `.overrun` past it. An unbounded
/// input queue does not remove the problem, it hides it: a caller outrunning the model on a slow
/// machine becomes unbounded memory growth with no signal. Dropping loudly beats swelling
/// silently.
///
/// ## Lifetime
///
/// `finish()` flushes the tail, emits exactly one `isFinal` chunk and ends `updates`.
/// `cancel()` abandons: `updates` ends with `CancellationError` and no final chunk. Dropping
/// the session ends it (the abandoned-stream rule). Sessions obtained from
/// `MLXServeEngine.transcribeLive` hold residency until one of those happens or the engine's
/// idle timeout fires.
public protocol STTSession: AnyObject, Sendable {
    /// Chunks as they are decoded. Ends after the `isFinal` chunk, with `CancellationError`
    /// when cancelled, or with the failure that ended the session.
    nonisolated var updates: AsyncThrowingStream<STTStreamChunk, Error> { get }

    /// How to assemble `updates`. Equals the surface's declared `STTControls.liveDiscipline`;
    /// LIV-1 checks that it does, so the declaration cannot drift from the session.
    nonisolated var discipline: STTStreamDiscipline { get }

    /// Input buffer capacity, in seconds of audio. `push` returns `.overrun` beyond it.
    ///
    /// On the session rather than the descriptor deliberately: nobody chooses between two ASR
    /// packages on buffer depth (so it is not routing-time), but every caller wiring a tap needs
    /// the number, and it is the session that enforces it.
    nonisolated var maxBufferedSeconds: Double { get }

    /// The sample rate this session wants — read it when you install the tap, and configure the
    /// converter you already have from it.
    ///
    /// **This is where the live plane diverges from `STTRequest`**, which promises the package
    /// resamples anything. It cannot promise that here. `push` is copy-only by contract (LIV-3),
    /// which leaves no room to convert on the way in, and the alternative — buffering unconverted
    /// audio and resampling on the inference actor — puts a resampler in the path of models that
    /// are measurably brittle to what resampling does (the VibeVoice-ASR noise finding). Every
    /// real capture path already owns a converter, so the honest split is: the caller converts,
    /// the session says to what, and a mismatch is reported rather than transcribed.
    ///
    /// A session that genuinely resamples still names its native rate here and simply never
    /// answers `.unsupportedSampleRate`.
    nonisolated var expectedSampleRate: Int { get }

    /// Hand over mono PCM samples in [-1, 1] at `sampleRate`. Safe from an audio callback:
    /// copies and returns. Samples at any other rate than `expectedSampleRate` are dropped with
    /// `.unsupportedSampleRate` unless the session resamples.
    nonisolated func push(_ samples: [Float], sampleRate: Int) -> PushOutcome

    /// Stop feeding audio: flush the tail, emit the final chunk, end `updates`. Idempotent.
    nonisolated func finish()

    /// Abandon the session: `updates` ends with `CancellationError`, no final chunk, the model
    /// reference is released. Idempotent.
    nonisolated func cancel()
}

/// Opt-in live transcription, `as?`-detected by the engine — the second protocol on that
/// convention, after `StreamEmitting` (and the `SelfMaterializing`/`QuantConfigured` pattern
/// before it).
///
/// ## Contract
///
/// - A surface declaring `STTControls.liveDiscipline != nil` **requires** this conformance, and
///   a conforming type must declare it on at least one `stt` surface (LIV-1). Silent drift in
///   either direction is a package bug the gate catches offline.
/// - `startLiveTranscription` runs on `@InferenceActor` — it touches the loaded model — and is
///   the ONLY part of a session that does. Throw `PackageError.notLoaded` before residency.
/// - The returned session's `discipline` and the declaration must agree, and the session must
///   honor the `push`/`finish`/`cancel` semantics on `STTSession`.
/// - **Final parity (LIV-5):** the transcript `finish()` delivers must equal what
///   `run(STTRequest)` returns for the same audio, within a declared tolerance. A live path that
///   has quietly diverged from the batch path is the failure this catches.
@InferenceActor
public protocol LiveTranscribing: ModelPackage {
    func startLiveTranscription(_ request: STTSessionRequest) async throws -> any STTSession
}
