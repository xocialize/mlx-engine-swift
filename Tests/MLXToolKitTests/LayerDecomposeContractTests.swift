//
//  LayerDecomposeContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.48.0 — `Capability.layerDecompose`: one flattened design → an ordered stack of
//  straight-alpha RGBA layers, front-most first, plus the model's composite when it has one.
//  Introduced by Ming-Image-0.1-Design-Layer (ming-image-swift, AB-T-0181).
//

import XCTest
import MLXToolKit

final class LayerDecomposeContractTests: XCTestCase {

    func testCapabilityWireNameAndCanonicalOutput() throws {
        XCTAssertEqual(Capability.layerDecompose.rawValue, "layerDecompose")
        XCTAssertEqual(Capability.layerDecompose.canonicalOutput, .image)
        XCTAssertEqual(LayerDecomposeRequest.capability, .layerDecompose)
        let decoded = try JSONDecoder().decode(Capability.self, from: Data(#""layerDecompose""#.utf8))
        XCTAssertEqual(decoded, .layerDecompose)
    }

    func testRequestLeavesEverythingButTheImageToThePackage() {
        let image = Image(format: .png, data: Data(count: 8), width: 1920, height: 1080)
        let bare = LayerDecomposeRequest(image: image)
        XCTAssertEqual(bare.image, image)
        XCTAssertNil(bare.spec)
        XCTAssertNil(bare.layerCount)
        XCTAssertNil(bare.resolution)
        XCTAssertNil(bare.steps)
        XCTAssertNil(bare.guidanceScale)
        XCTAssertNil(bare.seed)
        XCTAssertNil(bare.mode)
        XCTAssertTrue(bare.metaData.isEmpty)

        let planned = LayerDecomposeRequest(image: image, spec: "Layer 1: the headline.", layerCount: 3,
                                            resolution: 1024, seed: 7)
        XCTAssertEqual(planned.spec, "Layer 1: the headline.")
        XCTAssertEqual(planned.layerCount, 3)
        XCTAssertEqual(planned.resolution, 1024)
        XCTAssertEqual(planned.seed, 7)
    }

    // Order is the semantics: layers[0] is front-most, the last is the background. The response
    // must carry the package's order through untouched.
    func testResponseKeepsLayerOrderAndCompositeIsOptional() {
        let front = Image(format: .png, data: Data([1]))
        let middle = Image(format: .png, data: Data([2]))
        let back = Image(format: .png, data: Data([3]))
        let noComposite = LayerDecomposeResponse(layers: [front, middle, back])
        XCTAssertEqual(noComposite.layers, [front, middle, back])
        XCTAssertNil(noComposite.composite)

        let composite = Image(format: .png, data: Data([9]))
        XCTAssertEqual(LayerDecomposeResponse(layers: [front], composite: composite).composite, composite)
    }

    func testDescriptorShape() throws {
        let d = LayerDecomposeContract.descriptor(name: "layers", summary: "s")
        XCTAssertEqual(d.capability, .layerDecompose)
        XCTAssertEqual(d.parameters.map(\.name),
                       ["image", "spec", "layerCount", "resolution", "steps", "guidanceScale", "seed"])
        let image = try XCTUnwrap(d.parameters.first { $0.name == "image" })
        XCTAssertEqual(image.kind, .image)
        XCTAssertTrue(image.required)
        XCTAssertEqual(d.parameters.filter(\.required).map(\.name), ["image"])
        XCTAssertEqual(d.parameters.first { $0.name == "layerCount" }?.kind, .integer)
        XCTAssertNil(d.controls)
        XCTAssertTrue(d.controlsMatchCapability)

        let round = try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(round, d)
    }
}
