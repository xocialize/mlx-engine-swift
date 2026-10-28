//
//  WireEnvelopeTests.swift
//  MLXToolKitTests
//
//  Contract 1.57.0 (AB-A-0206 item 3): every canonical request and response is `Codable`, an
//  envelope carries the capability so another process can decode the concrete type, and artifacts
//  travel as spool files instead of base64 when the encoder carries an `ArtifactSpool`. Without a
//  spool the encoding must be exactly the pre-1.57 one.
//

import XCTest
@testable import MLXToolKit

final class WireEnvelopeTests: XCTestCase {

    private var spoolDirectory: URL!

    override func setUpWithError() throws {
        spoolDirectory = URL.temporaryDirectory.appending(path: "Wire-\(UUID().uuidString)",
                                                          directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: spoolDirectory)
    }

    private let png = Data((0 ..< 4096).map { UInt8($0 & 0xFF) })

    func testRegistryCoversEveryCapabilityWithTheMatchingTypes() {
        for capability in Capability.allCases {
            XCTAssertEqual(CapabilityWire.requestType(for: capability).capability, capability,
                           "\(capability) maps to a request for another capability")
        }
        XCTAssertTrue(CapabilityWire.requestType(for: .stt) == STTRequest.self,
                      "stt rides the one-shot request; a live session is a stream")
        XCTAssertTrue(CapabilityWire.responseType(for: .imageEdit) == IEditResponse.self)
        XCTAssertTrue(CapabilityWire.responseType(for: .music) == MusicResponse.self)
    }

    func testRequestEnvelopeRoundTripsWithoutASpool() throws {
        let request = T2IRequest(prompt: "a fox in snow", width: 1024, height: 768, steps: 8,
                                 seed: 42, background: .opaque, mode: "photo",
                                 metaData: ["sampler": .string("euler")])
        let envelope = CapabilityRequestEnvelope(request, package: "z-image-turbo-t2i")
        let json = try CapabilityWire.encoder().encode(envelope)
        let decoded = try CapabilityWire.decoder().decode(CapabilityRequestEnvelope.self, from: json)

        XCTAssertEqual(decoded.capability, .textToImage)
        XCTAssertEqual(decoded.package, "z-image-turbo-t2i")
        let typed = try XCTUnwrap(decoded.request as? T2IRequest)
        XCTAssertEqual(typed.prompt, "a fox in snow")
        XCTAssertEqual(typed.width, 1024)
        XCTAssertEqual(typed.seed, 42)
        XCTAssertEqual(typed.background, .opaque)
        XCTAssertEqual(typed.mode, "photo")
        XCTAssertEqual(typed.metaData["sampler"], .string("euler"))
        // Re-encoding the decoded envelope reproduces the bytes (sorted keys).
        XCTAssertEqual(try CapabilityWire.encoder().encode(decoded), json)
    }

    func testArtifactsTravelAsSpoolFilesAndComeBackByteIdentical() throws {
        let spool = ArtifactSpool(directory: spoolDirectory)
        let request = IEditRequest(images: [Image(format: .png, data: png, width: 32, height: 32)],
                                   prompt: "make it night")
        let json = try CapabilityWire.encoder(spool: spool).encode(CapabilityRequestEnvelope(request))
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"file\":\"\(spoolDirectory.path)"), text)
        XCTAssertFalse(text.contains("\"data\""), "a spooled artifact must not also inline its bytes")
        XCTAssertLessThan(json.count, png.count, "the JSON carries a path, not the 4 KB image")

        // Decoding needs no spool for an absolute path.
        let decoded = try CapabilityWire.decoder().decode(CapabilityRequestEnvelope.self, from: json)
        let image = try XCTUnwrap((decoded.request as? IEditRequest)?.images.first)
        XCTAssertEqual(image.data, png)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.format, .png)
    }

    func testRelativeFileReferencesResolveAgainstTheDecodersSpool() throws {
        let spool = ArtifactSpool(directory: spoolDirectory)
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        try png.write(to: spoolDirectory.appending(path: "input.png"))
        let json = Data(#"{"format":"png","file":"input.png","width":32}"#.utf8)

        let image = try CapabilityWire.decoder(spool: spool).decode(Image.self, from: json)
        XCTAssertEqual(image.data, png)
        XCTAssertThrowsError(try CapabilityWire.decoder().decode(Image.self, from: json),
                             "a relative path with no spool to resolve it against is an error")
    }

    func testWithoutASpoolTheEncodingIsThePre157One() throws {
        // The exact synthesized shape: format, data (base64), optional fields omitted when nil.
        let audio = Audio(data: Data([1, 2, 3]), sampleRate: 48_000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(audio), as: UTF8.self),
                       #"{"data":"AQID","format":"wav","sampleRate":48000}"#)
        let legacy = Data(#"{"format":"glb","data":"AQID","hasVertexColors":true}"#.utf8)
        let mesh = try JSONDecoder().decode(Mesh.self, from: legacy)
        XCTAssertEqual(mesh.data, Data([1, 2, 3]))
        XCTAssertTrue(mesh.hasVertexColors)
        let matte = Matte(data: Data([9]), width: 1, height: 1, kind: .softAlpha)
        XCTAssertEqual(try JSONDecoder().decode(Matte.self, from: try encoder.encode(matte)), matte)
        let video = Video(format: .mp4, data: Data([7, 7]), durationSeconds: 2, frameRate: 24)
        XCTAssertEqual(try JSONDecoder().decode(Video.self, from: try encoder.encode(video)), video)
    }

    func testAnArtifactWithNeitherDataNorFileIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(Image.self, from: Data(#"{"format":"png"}"#.utf8)))
    }

    func testResponseEnvelopeRoundTripsAndRefusesANonCanonicalResponse() throws {
        let spool = ArtifactSpool(directory: spoolDirectory)
        let response = T2IResponse(image: Image(format: .png, data: png, width: 32, height: 32))
        let envelope = try CapabilityResponseEnvelope(capability: .textToImage, response: response)
        let json = try CapabilityWire.encoder(spool: spool).encode(envelope)
        let decoded = try CapabilityWire.decoder().decode(CapabilityResponseEnvelope.self, from: json)
        XCTAssertEqual((decoded.response as? T2IResponse)?.image, response.image)

        XCTAssertThrowsError(try CapabilityResponseEnvelope(capability: .imageEdit, response: response)) {
            XCTAssertEqual($0 as? CapabilityWire.WireError,
                           .notWireCodable(capability: .imageEdit, type: "T2IResponse"))
        }
    }

    func testAudioAndVideoRequestsSpoolEveryArtifact() throws {
        let spool = ArtifactSpool(directory: spoolDirectory)
        let request = TalkingHeadRequest(source: Video(format: .mp4, data: Data(repeating: 1, count: 64)),
                                         audio: Audio(data: Data(repeating: 2, count: 64)))
        let json = try CapabilityWire.encoder(spool: spool).encode(CapabilityRequestEnvelope(request))
        let files = try FileManager.default.contentsOfDirectory(atPath: spoolDirectory.path)
        XCTAssertEqual(Set(files.map { ($0 as NSString).pathExtension }), ["mp4", "wav"])
        let decoded = try XCTUnwrap(try CapabilityWire.decoder()
            .decode(CapabilityRequestEnvelope.self, from: json).request as? TalkingHeadRequest)
        XCTAssertEqual(decoded.source.data, Data(repeating: 1, count: 64))
        XCTAssertEqual(decoded.audio.data, Data(repeating: 2, count: 64))
    }
}
