//
//  ResolvedLaneTests.swift
//  MLXToolKitTests
//
//  Contract 1.57.0 (AB-A-0206 item 1): a configuration's resolved lane, exported as data. The
//  resolution must be the governor's (quant match → hint override → largest-that-fits), say where
//  each number came from, and round-trip through JSON unchanged.
//

import XCTest
@testable import MLXToolKit

private let manifest = PackageManifest(
    license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
    provenance: Provenance(sourceRepo: "org/lane", revision: "main", tier: 1),
    requirements: RequirementsManifest(
        footprints: [
            QuantFootprint(quant: .bf16, residentBytes: 20_000, peakActivationBytes: 9_000,
                           minSustainedReadBytesPerSecond: 1_000_000),
            QuantFootprint(quant: .int4, residentBytes: 6_000, peakActivationBytes: 9_000,
                           expectedWeightReadBytesPerRun: 6_000),
        ],
        requiredBackends: [.metalGPU]),
    surfaces: [
        ToolDescriptor(name: "lane-analysis", capability: .imageAnalysis, summary: "any quant"),
        ToolDescriptor(name: "lane-t2i", capability: .textToImage, summary: "int8+",
                       quantFloor: .int8),
    ])

private struct Quanted: PackageConfiguration, QuantConfigured, WeightSourcing {
    var quant: Quant
    var weightSources: [WeightSource] {
        [WeightSource(role: "snapshot", repo: "org/lane-bf16", matching: ["transformer/*"])]
    }
}

private struct Hinted: PackageConfiguration, QuantConfigured, FootprintConfigured, WeightSourcing,
                       SelfMaterializing {
    var quant: Quant = .bf16
    var residentBytesHint: UInt64? { 25_000 }
    var peakActivationBytesHint: UInt64? { 40_000 }
    var activationScalingHint: ActivationScaling? {
        ActivationScaling(axis: .pixelFrames, baseBytes: 1_000, bytesPerUnit: 2, measuredCeiling: 100)
    }
    var weightSources: [WeightSource] { [WeightSource(role: "main", repo: "org/self")] }
}

private struct Plain: PackageConfiguration {}

private struct Bundled: PackageConfiguration, BundledWeightSourcing {
    var bundledWeightSources: [BundledWeightSource] { [] }
}

final class ResolvedLaneTests: XCTestCase {

    func testQuantMatchPicksThatFootprintAndAppliesSurfaceFloors() {
        let lane = ResolvedLane(manifest: manifest, configuration: Quanted(quant: .int4))
        XCTAssertEqual(lane.quant, .int4)
        XCTAssertEqual(lane.footprintQuant, .int4)
        XCTAssertEqual(lane.persistentBytes, 6_000)
        XCTAssertEqual(lane.peakTransientBytes, 9_000)
        XCTAssertEqual(lane.peakBytes, 15_000)
        XCTAssertEqual(lane.persistentSource, .quantMatch)
        XCTAssertEqual(lane.expectedWeightReadBytesPerRun, 6_000)
        XCTAssertNil(lane.minSustainedReadBytesPerSecond)
        XCTAssertEqual(lane.materialization, .engine)
        XCTAssertFalse(lane.selfMaterializing)
        XCTAssertEqual(lane.weightSources.map(\.repo), ["org/lane-bf16"])
        // int4 is below the t2i surface's int8 floor: only the analysis surface is backed.
        XCTAssertEqual(lane.capabilities, [.imageAnalysis])
        XCTAssertEqual(ResolvedLane(manifest: manifest, configuration: Quanted(quant: .bf16)).capabilities,
                       [.imageAnalysis, .textToImage])
    }

    func testHintsOverrideTheQuantFootprintAndAreLabelled() {
        let lane = ResolvedLane(manifest: manifest, configuration: Hinted())
        XCTAssertEqual(lane.footprintQuant, .bf16)
        XCTAssertEqual(lane.persistentBytes, 25_000)
        XCTAssertEqual(lane.persistentSource, .hint)
        XCTAssertEqual(lane.peakTransientBytes, 40_000)
        XCTAssertEqual(lane.peakTransientSource, .hint)
        XCTAssertEqual(lane.activationScaling?.measuredCeiling, 100)
        XCTAssertEqual(lane.minSustainedReadBytesPerSecond, 1_000_000, "the floor is quant-keyed only")
        XCTAssertEqual(lane.materialization, .package)
        XCTAssertTrue(lane.selfMaterializing)
    }

    func testNoQuantFallsBackToLargestThatFitsTheBudget() {
        let unknownMachine = ResolvedLane(manifest: manifest, configuration: Plain())
        XCTAssertEqual(unknownMachine.footprintQuant, .bf16, "no budget: the largest, never an under-reserve")
        XCTAssertEqual(unknownMachine.persistentSource, .largestThatFits)
        XCTAssertEqual(unknownMachine.materialization, .undeclared)
        let small = ResolvedLane(manifest: manifest, configuration: Plain(), budgetBytes: 10_000)
        XCTAssertEqual(small.footprintQuant, .int4)
        XCTAssertEqual(manifest.requirements.chosenFootprint(quant: nil, budgetBytes: 1)?.quant, .int4,
                       "nothing fits: the smallest")
        XCTAssertEqual(ResolvedLane(manifest: manifest, configuration: Bundled()).materialization, .bundled)
    }

    func testRoundTripsThroughJSON() throws {
        for configuration in [Quanted(quant: .int4), Hinted(), Plain()] as [any PackageConfiguration] {
            let lane = ResolvedLane(manifest: manifest, configuration: configuration)
            let json = try JSONEncoder().encode(lane)
            XCTAssertEqual(try JSONDecoder().decode(ResolvedLane.self, from: json), lane)
        }
        let json = try JSONEncoder().encode(ResolvedLane(manifest: manifest, configuration: Hinted()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["persistentSource"] as? String, "hint")
        XCTAssertEqual(object["materialization"] as? String, "package")
    }
}

@MainActor
final class MonitorEventStreamTests: XCTestCase {

    func testPreparationEventsArriveInOrderForEverySubscriber() async throws {
        let monitor = PreparationMonitor()
        let first = monitor.events()
        let second = monitor.events()
        monitor.update(.textToImage, package: "zit", to: .downloading(fraction: 0.5, bytesPerSecond: 1e6))
        monitor.update(.textToImage, package: "zit", to: .loading)
        monitor.update(.textToImage, package: "zit", to: .ready)

        for stream in [first, second] {
            var phases: [PreparePhase] = []
            for await event in stream {
                XCTAssertEqual(event.packageID, "zit")
                XCTAssertEqual(event.capability, .textToImage)
                phases.append(event.phase)
                if phases.count == 3 { break }
            }
            XCTAssertEqual(phases, [.downloading(fraction: 0.5, bytesPerSecond: 1e6), .loading, .ready])
        }
    }

    func testRunEventsEndWithANilReport() async throws {
        let monitor = RunMonitor()
        let stream = monitor.events()
        monitor.update(.textToImage, package: "zit", to: RunPhaseReport(phase: .denoise, step: 3, totalSteps: 8))
        monitor.clear(.textToImage, package: "zit")
        var events: [RunEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == 2 { break }
        }
        XCTAssertEqual(events.first?.report?.step, 3)
        XCTAssertNil(events.last?.report)
        let json = try JSONEncoder().encode(events[0])
        XCTAssertEqual(try JSONDecoder().decode(RunEvent.self, from: json), events[0])
    }

    func testPreparePhaseWireForm() throws {
        let phases: [PreparePhase] = [.idle, .registering, .prewarming(fraction: 0.2),
                                      .downloading(fraction: 0.4, bytesPerSecond: nil),
                                      .downloading(fraction: 0.6, bytesPerSecond: 3e7),
                                      .loading, .ready, .failed("HTTP 404")]
        for phase in phases {
            XCTAssertEqual(try JSONDecoder().decode(PreparePhase.self, from: JSONEncoder().encode(phase)), phase)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(PreparePhase.downloading(fraction: 0.5, bytesPerSecond: 2)),
                              as: UTF8.self),
                       #"{"bytesPerSecond":2,"fraction":0.5,"phase":"downloading"}"#)
        XCTAssertEqual(try JSONDecoder().decode(PreparePhase.self, from: Data(#"{"phase":"verifying"}"#.utf8)),
                       .failed("unknown preparation phase \"verifying\""))
    }
}
