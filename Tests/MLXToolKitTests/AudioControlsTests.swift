//
//  AudioControlsTests.swift
//  MLXToolKitTests
//
//  Contract 1.38.0 — the audio controls pass (AB-A-0061 / 0063 / 0064, + AB-A-0029's
//  `RunPhase.screen`). Every check here is about the two properties the pass promised:
//  the additions are INERT for existing call sites, and a declaration DRIVES what the
//  surface advertises (so a planner is never offered a knob that is ignored).
//

import XCTest
@testable import MLXToolKit

final class AudioControlsTests: XCTestCase {

    // MARK: - AB-A-0061 — STTSegment.speaker

    func testSpeakerIsAdditiveAndDefaultsNil() throws {
        // A 1.20.0-era construction site is unchanged.
        let legacy = STTSegment(text: "hello", start: 0, duration: 1)
        XCTAssertNil(legacy.speaker)

        let attributed = STTSegment(text: "hello", start: 0, duration: 1, speaker: "Speaker 0")
        XCTAssertEqual(attributed.speaker, "Speaker 0")

        // Optional property ⇒ the synthesized Codable decodes pre-1.38.0 JSON with no key.
        let old = Data(#"{"text":"hi","start":0,"duration":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(STTSegment.self, from: old).speaker)
    }

    // A String, not an Int: named speakers stay representable and enrolled-speaker naming
    // later needs no second migration.
    func testSpeakerLabelIsAnOpenString() {
        let named = STTSegment(text: "…", start: 0, duration: 1, speaker: "Dustin")
        XCTAssertEqual(named.speaker, "Dustin")
    }

    // MARK: - AB-A-0063 — STTRequest.context

    func testContextIsAdditiveAndDefaultsNil() {
        let legacy = STTRequest(audio: Audio(data: Data()))
        XCTAssertNil(legacy.context)
        // Positional order is preserved for pre-1.38 call sites that pass mode/metaData.
        let withEnvelope = STTRequest(audio: Audio(data: Data()), language: "en-US",
                                      mode: nil, metaData: ["k": .string("v")])
        XCTAssertNil(withEnvelope.context)

        let biased = STTRequest(audio: Audio(data: Data()), context: ["MLXEngine", "VoxCPM2"])
        XCTAssertEqual(biased.context, ["MLXEngine", "VoxCPM2"])
    }

    // MARK: - STTControls — declaration drives advertisement

    func testSTTDescriptorAdvertisesContextOnlyWhenDeclared() throws {
        let plain = STTContract.descriptor(name: "transcribe", summary: "s")
        XCTAssertNil(plain.controls)
        XCTAssertNil(plain.sttControls)
        XCTAssertFalse(plain.parameters.contains { $0.name == "context" })

        let biasing = STTContract.descriptor(
            name: "transcribe", summary: "s",
            controls: STTControls(attributesSpeakers: true, supportsContextBiasing: true))
        XCTAssertEqual(biasing.sttControls?.attributesSpeakers, true)
        let context = try XCTUnwrap(biasing.parameters.first { $0.name == "context" })
        XCTAssertEqual(context.kind, .array)
        XCTAssertFalse(context.required)

        // Declaring attribution alone must NOT advertise a biasing knob that is ignored.
        let diarizingOnly = STTContract.descriptor(
            name: "transcribe", summary: "s",
            controls: STTControls(attributesSpeakers: true, supportsContextBiasing: false))
        XCTAssertFalse(diarizingOnly.parameters.contains { $0.name == "context" })
    }

    // MARK: - AB-A-0064 — TTSControls + typed emotion / targetDuration

    func testTTSControlsAreAdditiveAndDefaultsNil() {
        let legacy = TTSRequest(text: "hello")
        XCTAssertNil(legacy.emotion)
        XCTAssertNil(legacy.targetDuration)
        // A pre-1.38 call site passing the envelope still compiles in positional order.
        let withEnvelope = TTSRequest(text: "hello", referenceTranscript: "ref",
                                      mode: .expressive, metaData: ["emotion": .string("happy")])
        XCTAssertNil(withEnvelope.emotion)
        XCTAssertEqual(withEnvelope.metaData["emotion"], .string("happy"))  // compat path untouched
    }

    // The request value's case maps 1:1 onto the mode a package declares, so a consumer
    // checks supportability without learning a second vocabulary.
    func testEmotionCaseMapsOntoDeclaredMode() {
        XCTAssertEqual(TTSEmotion.categorical("happy").mode, .categorical)
        XCTAssertEqual(TTSEmotion.vector([0.2, -0.4]).mode, .vector)
        XCTAssertEqual(TTSEmotion.referenceAudio(Audio(data: Data())).mode, .referenceAudio)
        XCTAssertEqual(TTSEmotion.textDescription("sound tired").mode, .textDescription)
    }

    // The categorical vocabulary is OPEN — the contract carries the plane, the audio
    // packages own the labels (E12's 9→8 map is theirs).
    func testCategoricalVocabularyIsOpen() throws {
        let exotic = TTSEmotion.categorical("wistful")
        let round = try JSONDecoder().decode(
            TTSEmotion.self, from: JSONEncoder().encode(exotic))
        XCTAssertEqual(round, exotic)
    }

    func testTTSDescriptorAdvertisesOnlyDeclaredControls() {
        let plain = TTSContract.descriptor(name: "speak", summary: "s")
        XCTAssertNil(plain.ttsControls)
        XCTAssertFalse(plain.parameters.contains { $0.name == "emotion" })
        XCTAssertFalse(plain.parameters.contains { $0.name == "targetDuration" })

        // Emotion-only: no duration knob advertised.
        let emotive = TTSContract.descriptor(
            name: "speak", summary: "s",
            controls: TTSControls(emotionModes: [.categorical, .textDescription]))
        XCTAssertEqual(emotive.ttsControls?.emotionModes, [.categorical, .textDescription])
        XCTAssertTrue(emotive.parameters.contains { $0.name == "emotion" })
        XCTAssertFalse(emotive.parameters.contains { $0.name == "targetDuration" })

        // Both levers (the IndexTTS2 shape).
        let full = TTSContract.descriptor(
            name: "speak", summary: "s",
            controls: TTSControls(emotionModes: [.categorical, .vector, .referenceAudio],
                                  supportsTargetDuration: true))
        XCTAssertTrue(full.parameters.contains { $0.name == "emotion" })
        XCTAssertTrue(full.parameters.contains { $0.name == "targetDuration" })
        // Streaming and controls are independent declarations, both nil-by-default.
        XCTAssertNil(full.streaming)
    }

    // MARK: - SurfaceControls — the shared descriptor's governing rule

    func testControlsMustMatchTheSurfaceCapability() {
        XCTAssertTrue(TTSContract.descriptor(
            name: "speak", summary: "s",
            controls: TTSControls(supportsTargetDuration: true)).controlsMatchCapability)
        XCTAssertTrue(STTContract.descriptor(name: "t", summary: "s").controlsMatchCapability)

        // A tts block on an stt surface tells a consumer nothing true.
        let mismatched = ToolDescriptor(
            name: "transcribe", capability: .stt, summary: "s",
            controls: .tts(TTSControls(supportsTargetDuration: true)))
        XCTAssertFalse(mismatched.controlsMatchCapability)
        XCTAssertNil(mismatched.sttControls)   // accessors never lie about the case
    }

    func testDescriptorCodableRoundTripsControls() throws {
        let descriptor = TTSContract.descriptor(
            name: "speak", summary: "s",
            streaming: .audioChunk,
            controls: TTSControls(emotionModes: [.vector], supportsTargetDuration: true))
        let round = try JSONDecoder().decode(
            ToolDescriptor.self, from: JSONEncoder().encode(descriptor))
        XCTAssertEqual(round, descriptor)
        XCTAssertEqual(round.ttsControls?.emotionModes, [.vector])
    }

    // Pre-1.38 descriptor JSON (no `controls` key) still decodes — additive, not breaking.
    func testDescriptorDecodesPre138JSON() throws {
        let json = Data("""
        {"name":"speak","capability":"tts","summary":"s","parameters":[],"supportedModes":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(ToolDescriptor.self, from: json)
        XCTAssertNil(decoded.controls)
        XCTAssertTrue(decoded.controlsMatchCapability)
    }

    // MARK: - AB-A-0029 — RunPhase.screen

    func testScreenIsACanonicalRunPhase() {
        XCTAssertEqual(RunPhase.screen.rawValue, "screen")
        // mage-flow reports the same raw value it already minted, so promotion costs it nothing.
        XCTAssertEqual(RunPhase("screen"), .screen)
        XCTAssertNotEqual(RunPhase.screen, .encode)
    }
}

/// Source-compatibility harness for contract 1.38.0.
///
/// Every construction site below is copied VERBATIM in shape from a package shipping against
/// the pre-1.38 contract, so a future edit that silently breaks one fails here rather than in
/// a consumer repo that pins a published tag and only discovers it on its next bump. The
/// packages: `mlx-nemotron-stt-swift` (stt), `mlx-indextts2-swift` / `mlx-gepard-swift` /
/// `mlx-qwen3-tts-swift` / `mlx-voxcpm2-tts-swift` / `mlx-kokoro-tts-swift` /
/// `mlx-moss-tts-swift` / `mlx-audio8-tts-swift` (tts).
final class FleetCallSiteCompatibilityTests: XCTestCase {

    // mlx-nemotron-stt-swift: NemotronSTTPackage.swift:59 / :150 / :157
    func testPre138STTCallSitesStillCompile() {
        let descriptor = STTContract.descriptor(
            name: "nemotron-3.5-asr", summary: "NVIDIA Nemotron 3.5 ASR — …")
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "language"])

        let segments = [STTSegment(text: "hello", start: 0, duration: 1.2)]
        let response = STTResponse(text: "hello", segments: segments, detectedLanguage: "en-US")
        XCTAssertNil(response.segments.first?.speaker)

        let request = STTRequest(audio: Audio(data: Data()), language: "en-US")
        XCTAssertNil(request.context)
    }

    /// The 1.39.0 companion: the shape `mlx-nemotron-stt-swift` ships NOW, pinned the same way.
    /// The pre-1.38 site above must keep compiling; this one must keep meaning what it says.
    func testShippedSTTLiveCallSiteIsPinned() {
        let descriptor = STTContract.descriptor(
            name: "nemotron-3.5-asr", summary: "NVIDIA Nemotron 3.5 ASR — …",
            controls: STTControls(liveDiscipline: .cumulative))
        XCTAssertEqual(descriptor.sttControls?.liveDiscipline, .cumulative)
        // A live declaration adds no request parameter — it is a different entry point.
        XCTAssertEqual(descriptor.parameters.map(\.name), ["audio", "language"])
        // …and it is NOT the StreamEmitting axis, which STR-1 would then assert against.
        XCTAssertNil(descriptor.streaming)

        // The VibeVoice-ASR-Streaming V5 shape mlx-audio is building to (AB-A-0062): all three
        // declarations compose, and only `context` reaches the schema.
        let vibevoice = STTContract.descriptor(
            name: "vibevoice-asr-streaming", summary: "VibeVoice-ASR-Streaming-7B — …",
            controls: STTControls(attributesSpeakers: true, supportsContextBiasing: true,
                                  liveDiscipline: .incremental))
        XCTAssertEqual(vibevoice.parameters.map(\.name), ["audio", "language", "context"])
        XCTAssertEqual(vibevoice.sttControls?.liveDiscipline, .incremental)
        XCTAssertTrue(vibevoice.controlsMatchCapability)
    }

    // mlx-indextts2-swift:78 (modes only) and mlx-gepard-swift:76 (modes + streaming).
    func testPre138TTSDescriptorCallSitesStillCompile() {
        let indexTTS2 = TTSContract.descriptor(
            name: "indextts2", summary: "IndexTTS-2.5 …", modes: [.expressive, .neutral])
        XCTAssertEqual(indexTTS2.parameters.map(\.name),
                       ["text", "voice", "referenceTranscript"])
        XCTAssertNil(indexTTS2.controls)

        let gepard = TTSContract.descriptor(
            name: "gepard", summary: "Gepard-1.0 …", modes: [.neutral, .expressive],
            streaming: .audioChunk)
        XCTAssertEqual(gepard.streaming, .audioChunk)
        XCTAssertNil(gepard.ttsControls)   // streaming and controls are independent
    }

    // The pre-1.38 emotion/duration path: package-specific metaData strings (C5), which every
    // shipping consumer still uses and which 1.38.0 does not disturb.
    func testPre138MetaDataControlPathIsUnchanged() {
        let request = TTSRequest(
            text: "line one",
            voice: VoiceSelector(.referenceAudio(Audio(data: Data()))),
            referenceTranscript: "reference",
            mode: .expressive,
            metaData: ["emotion": .string("happy"), "emoAlpha": .double(0.8),
                       "targetDuration": .double(3.5), "speechRate": .double(1.0)])
        XCTAssertNil(request.emotion)
        XCTAssertNil(request.targetDuration)
        XCTAssertEqual(request.metaData["emoAlpha"], .double(0.8))
    }
}
