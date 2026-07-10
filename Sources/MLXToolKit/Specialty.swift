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
