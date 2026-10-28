import Foundation

// Wire envelopes (contract 1.57.0, AB-A-0206 item 3): every capability's canonical request and
// response is `Codable`, and a job crosses a process boundary as JSON plus spool files. A host
// that runs each model in a worker process of its own (Gaea's `.gaeaplugin`s) moves jobs with
// these types and needs no codec per capability:
//
//     // host side: media bytes go to the spool, the JSON carries their paths
//     let envelope = CapabilityRequestEnvelope(T2IRequest(prompt: "a fox"))
//     let json = try CapabilityWire.encoder(spool: ArtifactSpool(directory: jobDir)).encode(envelope)
//
//     // worker side: the capability tag picks the concrete request type
//     let decoded = try CapabilityWire.decoder().decode(CapabilityRequestEnvelope.self, from: json)
//     let response = try await engine.run(decoded.request, package: decoded.package)
//
// Without a spool the artifacts encode inline (base64 `data`), exactly as before 1.57.0.

/// A capability request the wire can carry: every canonical request type conforms (1.57.0).
public typealias WireRequest = CapabilityRequest & Codable
/// A capability response the wire can carry: every canonical response type conforms (1.57.0).
public typealias WireResponse = CapabilityResponse & Codable

/// Where artifact bytes go when a request or response is encoded for another process.
///
/// Put one in the encoder's `userInfo` under `ArtifactSpool.userInfoKey` (or use
/// `CapabilityWire.encoder(spool:)`) and every `Audio`, `Image`, `Matte`, `Mesh` and `Video`
/// writes its bytes to a new file in `directory` and encodes `"file": "<absolute path>"` instead
/// of `"data"`. Decoding needs no spool for an absolute path; a RELATIVE `file` resolves against
/// the decoder's spool directory, so a host may hand a worker paths relative to a job directory.
/// Decoded bytes are memory-mapped where the file system allows (`Data.ReadingOptions
/// .mappedIfSafe`), so a large frame or clip is not copied on the way in.
///
/// The spool never deletes anything: the files belong to whoever owns `directory` (the job).
public struct ArtifactSpool: Sendable, Equatable {
    /// The `userInfo` key encoders and decoders read the spool from.
    public static let userInfoKey = CodingUserInfoKey(rawValue: "MLXToolKit.ArtifactSpool")!

    /// The directory artifact files are written to, and relative references resolve against.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Write `data` to a new uniquely named file in `directory`; returns its URL.
    public func write(_ data: Data, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString.lowercased()).\(fileExtension)")
        try data.write(to: url)
        return url
    }

    /// Resolve a `file` reference: absolute paths as given, relative ones against `directory`.
    public func resolve(_ reference: String) -> URL {
        reference.hasPrefix("/")
            ? URL(fileURLWithPath: reference)
            : directory.appending(path: reference)
    }

    // MARK: artifact codec helpers

    /// Encode an artifact's bytes: to a spool file when the encoder carries a spool, else inline.
    static func encodeBytes<K: CodingKey>(_ data: Data, fileExtension: String,
                                          _ container: inout KeyedEncodingContainer<K>,
                                          data dataKey: K, file fileKey: K,
                                          encoder: Encoder) throws {
        if let spool = encoder.userInfo[userInfoKey] as? ArtifactSpool {
            try container.encode(try spool.write(data, fileExtension: fileExtension).path,
                                 forKey: fileKey)
        } else {
            try container.encode(data, forKey: dataKey)
        }
    }

    /// Decode an artifact's bytes from inline `data` or a `file` reference (either is accepted).
    static func decodeBytes<K: CodingKey>(_ container: KeyedDecodingContainer<K>,
                                          data dataKey: K, file fileKey: K,
                                          decoder: Decoder) throws -> Data {
        if let inline = try container.decodeIfPresent(Data.self, forKey: dataKey) { return inline }
        guard let reference = try container.decodeIfPresent(String.self, forKey: fileKey) else {
            throw DecodingError.keyNotFound(dataKey, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "An artifact carries neither \"data\" nor \"file\"."))
        }
        let spool = decoder.userInfo[userInfoKey] as? ArtifactSpool
        let url = spool?.resolve(reference) ?? URL(fileURLWithPath: reference)
        guard reference.hasPrefix("/") || spool != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: fileKey, in: container,
                debugDescription: "Relative artifact file \"\(reference)\" and no ArtifactSpool "
                    + "in the decoder's userInfo to resolve it against.")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: fileKey, in: container,
                debugDescription: "Artifact file \(url.path) could not be read: \(error.localizedDescription)")
        }
    }
}

/// A capability request tagged with its capability, so the receiving process can decode the
/// concrete type. `package` optionally routes to one backing package (`MLXServeEngine.run`'s
/// `package:` argument, as its string id).
public struct CapabilityRequestEnvelope: Codable, Sendable {
    public let capability: Capability
    public let package: String?
    public let request: any WireRequest

    public init(_ request: any WireRequest, package: String? = nil) {
        self.capability = request.capability
        self.package = package
        self.request = request
    }

    private enum CodingKeys: String, CodingKey { case capability, package, request }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capability = try c.decode(Capability.self, forKey: .capability)
        package = try c.decodeIfPresent(String.self, forKey: .package)
        let type = CapabilityWire.requestType(for: capability)
        request = try type.init(from: c.superDecoder(forKey: .request))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capability, forKey: .capability)
        try c.encodeIfPresent(package, forKey: .package)
        try request.encode(to: c.superEncoder(forKey: .request))
    }
}

/// A capability response tagged with the capability that produced it.
public struct CapabilityResponseEnvelope: Codable, Sendable {
    public let capability: Capability
    public let response: any WireResponse

    /// Wrap a response. Throws `CapabilityWire.WireError.notWireCodable` for a response type the
    /// wire does not carry (a package-private response a `run(_:)` returned in error).
    public init(capability: Capability, response: any CapabilityResponse) throws {
        guard let codable = response as? any WireResponse,
              type(of: codable) == CapabilityWire.responseType(for: capability) else {
            throw CapabilityWire.WireError.notWireCodable(
                capability: capability, type: String(describing: type(of: response)))
        }
        self.capability = capability
        self.response = codable
    }

    private enum CodingKeys: String, CodingKey { case capability, response }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capability = try c.decode(Capability.self, forKey: .capability)
        let type = CapabilityWire.responseType(for: capability)
        response = try type.init(from: c.superDecoder(forKey: .response))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capability, forKey: .capability)
        try response.encode(to: c.superEncoder(forKey: .response))
    }
}

/// The capability → canonical type registry the envelopes decode through, plus configured coders.
public enum CapabilityWire {

    public enum WireError: Error, Sendable, Equatable, LocalizedError {
        /// A response whose type is not the capability's canonical response.
        case notWireCodable(capability: Capability, type: String)

        public var errorDescription: String? {
            switch self {
            case .notWireCodable(let capability, let type):
                return "\(type) is not the canonical \(capability.rawValue) response, so the wire cannot carry it."
            }
        }
    }

    /// The canonical request type for a capability. `stt` maps to the one-shot `STTRequest`; a
    /// live session (`STTSessionRequest`) is a stream, not a job, and does not ride an envelope.
    public static func requestType(for capability: Capability) -> any WireRequest.Type {
        switch capability {
        case .tts: TTSRequest.self
        case .textToImage: T2IRequest.self
        case .imageEdit: IEditRequest.self
        case .textToVideo: T2VRequest.self
        case .llm: LLMRequest.self
        case .imageAnalysis: ImageAnalysisRequest.self
        case .videoAnalysis: VideoAnalysisRequest.self
        case .audioSeparation: AudioSeparationRequest.self
        case .speechEmotion: SpeechEmotionRequest.self
        case .audioCodec: AudioCodecRequest.self
        case .audioPolish: AudioPolishRequest.self
        case .imageQualityScore: ImageQualityScoreRequest.self
        case .imageRestore: ImageRestoreRequest.self
        case .imageUpscale: ImageUpscaleRequest.self
        case .videoUpscale: VideoUpscaleRequest.self
        case .frameInterpolate: FrameInterpolateRequest.self
        case .contentClassify: ContentClassifyRequest.self
        case .opticalFlow: OpticalFlowRequest.self
        case .soundEffect: SoundEffectRequest.self
        case .videoEdit: VEditRequest.self
        case .talkingHead: TalkingHeadRequest.self
        case .matting: MattingRequest.self
        case .defectDetect: DefectDetectRequest.self
        case .characterAnimation: CharacterAnimationRequest.self
        case .imageColorize: ColorizeRequest.self
        case .promptSegment: PromptSegmentRequest.self
        case .imageInpaint: InpaintRequest.self
        case .trackObject: TrackObjectRequest.self
        case .imageTo3D: ImageTo3DRequest.self
        case .embed: EmbedRequest.self
        case .multiVectorEmbed: MultiVectorEmbedRequest.self
        case .stt: STTRequest.self
        case .meshRig: MeshRigRequest.self
        case .imageRelight: ImageRelightRequest.self
        case .layerDecompose: LayerDecomposeRequest.self
        case .speechEdit: SpeechEditRequest.self
        case .music: MusicRequest.self
        }
    }

    /// The canonical response type for a capability.
    public static func responseType(for capability: Capability) -> any WireResponse.Type {
        switch capability {
        case .tts: TTSResponse.self
        case .textToImage: T2IResponse.self
        case .imageEdit: IEditResponse.self
        case .textToVideo: T2VResponse.self
        case .llm: LLMResponse.self
        case .imageAnalysis: ImageAnalysisResponse.self
        case .videoAnalysis: VideoAnalysisResponse.self
        case .audioSeparation: AudioSeparationResponse.self
        case .speechEmotion: SpeechEmotionResponse.self
        case .audioCodec: AudioCodecResponse.self
        case .audioPolish: AudioPolishResponse.self
        case .imageQualityScore: ImageQualityScoreResponse.self
        case .imageRestore: ImageRestoreResponse.self
        case .imageUpscale: ImageUpscaleResponse.self
        case .videoUpscale: VideoUpscaleResponse.self
        case .frameInterpolate: FrameInterpolateResponse.self
        case .contentClassify: ContentClassifyResponse.self
        case .opticalFlow: OpticalFlowResponse.self
        case .soundEffect: SoundEffectResponse.self
        case .videoEdit: VEditResponse.self
        case .talkingHead: TalkingHeadResponse.self
        case .matting: MattingResponse.self
        case .defectDetect: DefectDetectResponse.self
        case .characterAnimation: CharacterAnimationResponse.self
        case .imageColorize: ColorizeResponse.self
        case .promptSegment: PromptSegmentResponse.self
        case .imageInpaint: InpaintResponse.self
        case .trackObject: TrackObjectResponse.self
        case .imageTo3D: ImageTo3DResponse.self
        case .embed: EmbedResponse.self
        case .multiVectorEmbed: MultiVectorEmbedResponse.self
        case .stt: STTResponse.self
        case .meshRig: MeshRigResponse.self
        case .imageRelight: ImageRelightResponse.self
        case .layerDecompose: LayerDecomposeResponse.self
        case .speechEdit: SpeechEditResponse.self
        case .music: MusicResponse.self
        }
    }

    /// A JSON encoder for the wire: sorted keys, and artifacts spooled to files when `spool` is set.
    public static func encoder(spool: ArtifactSpool? = nil) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let spool { encoder.userInfo[ArtifactSpool.userInfoKey] = spool }
        return encoder
    }

    /// A JSON decoder for the wire; `spool` resolves relative artifact file references.
    public static func decoder(spool: ArtifactSpool? = nil) -> JSONDecoder {
        let decoder = JSONDecoder()
        if let spool { decoder.userInfo[ArtifactSpool.userInfoKey] = spool }
        return decoder
    }
}
