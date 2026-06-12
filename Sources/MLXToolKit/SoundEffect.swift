/// Canonical text-to-sound-effect surface (contract 1.2.0). Canonical output is an
/// **Audio** artifact (`SoundEffectResponse.audio`, `.wav`), serialized round-trip form (C3).
///
/// The fields here are what every text-to-SFX model understands — prompt, duration, and
/// the diffusion controls (mirroring the T2I canonical surface) — so they are canonical,
/// not `metaData` (C5). Scheduler variants, prompt-suffix conventions, and other
/// package-specific levers ride `metaData`.

/// Canonical sound-effect request.
public struct SoundEffectRequest: CapabilityRequest {
    public static var capability: Capability { .soundEffect }

    public let prompt: String
    /// Output duration in seconds. Packages document their maximum (MOSS-SoundEffect: 30).
    public let durationSeconds: Double?
    public let negativePrompt: String?
    public let steps: Int?
    public let guidanceScale: Double?
    public let seed: UInt64?
    public let mode: Mode?
    public let metaData: MetaData

    public init(prompt: String,
                durationSeconds: Double? = nil,
                negativePrompt: String? = nil,
                steps: Int? = nil,
                guidanceScale: Double? = nil,
                seed: UInt64? = nil,
                mode: Mode? = nil,
                metaData: MetaData = [:]) {
        self.prompt = prompt
        self.durationSeconds = durationSeconds
        self.negativePrompt = negativePrompt
        self.steps = steps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.mode = mode
        self.metaData = metaData
    }
}

/// Canonical sound-effect response — one `Audio` artifact (`.wav`).
public struct SoundEffectResponse: CapabilityResponse {
    public let audio: Audio
    public init(audio: Audio) { self.audio = audio }
}

/// Canonical descriptor shape for a sound-effect tool (C11).
public enum SoundEffectContract {
    public static func descriptor(name: String, summary: String, modes: [Mode] = []) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            capability: .soundEffect,
            summary: summary,
            parameters: [
                ParameterSchema(name: "prompt", kind: .string, required: true,
                                summary: "Description of the sound to generate."),
                ParameterSchema(name: "durationSeconds", kind: .number, required: false,
                                summary: "Output duration in seconds (package documents its max)."),
                ParameterSchema(name: "negativePrompt", kind: .string, required: false,
                                summary: "What to steer away from."),
                ParameterSchema(name: "steps", kind: .integer, required: false,
                                summary: "Denoising steps."),
                ParameterSchema(name: "guidanceScale", kind: .number, required: false,
                                summary: "CFG scale."),
                ParameterSchema(name: "seed", kind: .integer, required: false,
                                summary: "RNG seed for reproducibility."),
            ],
            supportedModes: modes
        )
    }
}
