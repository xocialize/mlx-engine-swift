//
//  ActivationScalingEngineTests.swift
//  MLXServeCoreTests
//
//  Contract 1.41.0 — activation as a FUNCTION of workload (AB-A-0069 / AB-D-0075). The engine
//  half: the pre-admission ceiling refusal shared by run/stream/transcribeLive, the
//  workload-aware machineFitAdvisory, the lane hint winning over the quant-keyed declaration,
//  and the scalar-only package being untouched by all of it. Offline, mock packages, no MLX.
//
//  Numbers are the VibeVoice shape scaled down 10^6 so the arithmetic is exact: reserve 4 000 B
//  = base 1 000 + 5 B/s × 600 s ceiling.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private let ceilingSeconds = 600.0
private let quantScaling = ActivationScaling(axis: .audioSeconds, baseBytes: 1_000,
                                             bytesPerUnit: 5, measuredCeiling: ceilingSeconds)

/// The VibeVoice-shaped configuration: maps an STT request (and, for the shared-preflight test,
/// a session request) to seconds of audio carried in metaData, and can carry a LANE pair.
private struct ScalingConfiguration: PackageConfiguration, QuantConfigured, FootprintConfigured,
    WorkloadDeclaring
{
    var quant: Quant = .int4
    var laneScaling: ActivationScaling? = nil
    var laneReserve: UInt64? = nil
    var mapsWorkload = true

    var residentBytesHint: UInt64? { nil }
    var peakActivationBytesHint: UInt64? { laneReserve }
    var activationScalingHint: ActivationScaling? { laneScaling }

    func workloadUnits(for request: any CapabilityRequest) -> Double? {
        guard mapsWorkload else { return nil }
        let meta = (request as? STTRequest)?.metaData ?? (request as? STTSessionRequest)?.metaData
        guard case .double(let seconds)? = meta?["seconds"] else { return nil }
        return seconds
    }
}

private func sttManifest(name: String, scaling: ActivationScaling?) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1, peakActivationBytes: 4_000,
                                        activationScaling: scaling)],
            requiredBackends: [.metalGPU]),
        surfaces: [STTContract.descriptor(name: name, summary: "m")])
}

@InferenceActor
private final class ScalingSTTPackage: ModelPackage {
    typealias Configuration = ScalingConfiguration
    nonisolated static var manifest: PackageManifest {
        sttManifest(name: "scaling-stt", scaling: quantScaling)
    }
    nonisolated init(configuration: ScalingConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "ok")
    }
}

/// Every STT package shipping today: a scalar declaration and a configuration that maps nothing.
@InferenceActor
private final class ScalarSTTPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        sttManifest(name: "scalar-stt", scaling: nil)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        STTResponse(text: "ok")
    }
}

private func request(seconds: Double) -> STTRequest {
    STTRequest(audio: Audio(data: Data()), metaData: ["seconds": .double(seconds)])
}

private func ceilingRefusal(_ error: any Error)
    -> (axis: WorkloadAxis, requested: Double, ceiling: Double)?
{
    guard case .workloadExceedsDeclaredCeiling(_, let axis, let requested, let ceiling)
            = error as? EngineError else { return nil }
    return (axis, requested, ceiling)
}

// MARK: - The pre-admission ceiling

@Test func aWorkloadInsideTheCeilingRuns() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration())
    let response = try await engine.run(request(seconds: 300))
    #expect((response as? STTResponse)?.text == "ok")
}

// The failure this exists to prevent: a 20-minute file admitted against a reserve measured at
// 10 minutes. Refused BEFORE admission — nothing becomes resident.
@Test func aWorkloadBeyondTheCeilingIsRefusedBeforeAnythingLoads() async throws {
    let engine = MLXServeEngine()
    let id = try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                                       configuration: ScalingConfiguration())
    do {
        _ = try await engine.run(request(seconds: 1200))
        Issue.record("expected workloadExceedsDeclaredCeiling")
    } catch {
        let refusal = try #require(ceilingRefusal(error))
        #expect(refusal.axis == .audioSeconds)
        #expect(refusal.requested == 1200)
        #expect(refusal.ceiling == ceilingSeconds)
    }
    let resident = await engine.residentPackages
    #expect(resident[id] == nil)
}

// Exactly the ceiling is inside the envelope: the declaration was measured there.
@Test func theCeilingItselfIsAdmitted() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration())
    _ = try await engine.run(request(seconds: ceilingSeconds))
}

// Unknowable is not the same as over: a configuration that cannot map the request is never
// refused (the live-session-at-open-time case).
@Test func anUnmappableRequestIsNeverRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration(mapsWorkload: false))
    _ = try await engine.run(request(seconds: 1_000_000))
}

// A scalar-only package (every package shipping today) is untouched by the whole plane.
@Test func aScalarOnlyPackageIsNeverRefused() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalarSTTPackage.self),
                              configuration: StandardConfiguration(weightsRepo: "mock/scalar"))
    _ = try await engine.run(request(seconds: 1e9))
    let units = try await engine.workloadUnits(for: request(seconds: 1e9))
    #expect(units == nil)
}

// The lane hint wins over the quant-keyed declaration, for the ceiling as for the split.
@Test func theLaneHintWinsOverTheQuantKeyedDeclaration() async throws {
    let engine = MLXServeEngine()
    let lane = ActivationScaling(axis: .audioSeconds, baseBytes: 1_000, bytesPerUnit: 5,
                                 measuredCeiling: 100)
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration(laneScaling: lane,
                                                                  laneReserve: 1_500))
    let declared = try await engine.declaredActivationScaling(.stt)
    #expect(declared == lane)
    do {
        _ = try await engine.run(request(seconds: 300))
        Issue.record("expected the LANE ceiling (100 s) to refuse 300 s")
    } catch {
        #expect(ceilingRefusal(error)?.ceiling == 100)
    }
}

// `transcribeLive` shares the preflight: a beyond-ceiling session request is refused by the
// ceiling BEFORE the live-plane guard runs (this package has no live plane at all), and an
// inside-ceiling one reaches that guard.
@Test func transcribeLiveSharesThePreflight() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration())
    do {
        _ = try await engine.transcribeLive(STTSessionRequest(metaData: ["seconds": .double(1200)]))
        Issue.record("expected workloadExceedsDeclaredCeiling")
    } catch {
        #expect(ceilingRefusal(error)?.requested == 1200)
    }
    do {
        _ = try await engine.transcribeLive(STTSessionRequest(metaData: ["seconds": .double(300)]))
        Issue.record("expected liveTranscriptionUnsupported")
    } catch {
        guard case .liveTranscriptionUnsupported = error as? EngineError else {
            Issue.record("unexpected \(error)"); return
        }
    }
}

// An incoherent RESOLVED pair (reserve below the model at the ceiling) still registers — a
// declaration-shape error is logged and left to the FIT gate, never a runtime brick.
@Test func anIncoherentPairStillRegisters() async throws {
    let engine = MLXServeEngine()
    let id = try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                                       configuration: ScalingConfiguration(laneReserve: 10))
    let declared = try await engine.declaredActivationScaling(.stt, package: id)
    #expect(declared?.isCovered(by: 10) == false)
    _ = try await engine.run(request(seconds: 300))
}

// MARK: - The workload-aware advisory

@Test func theWorkloadAdvisoryProjectsTheDeclaredModel() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration())
    let advisory = try await engine.machineFitAdvisory(.stt, workload: 300)
    let fit = try #require(advisory.workload)
    #expect(fit.axis == .audioSeconds)
    #expect(fit.units == 300)
    #expect(fit.withinCeiling)
    #expect(fit.projectedActivationBytes == 2_500)      // 1 000 + 5 × 300
    #expect(fit.reservedActivationBytes == 4_000)       // the scalar, untouched
    #expect(advisory.activationScaling == quantScaling)
    #expect(advisory.fits)                               // 2.5 KB fits any machine running tests
    #expect(advisory.message.contains("300 audioSeconds"))
}

// Beyond the ceiling the answer is "does not fit" whatever the machine has — the engine will
// refuse that run — and the extrapolation rides along so a host can say how far out it is.
@Test func aWorkloadBeyondTheCeilingDoesNotFitWhateverTheMachineHas() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration())
    let advisory = try await engine.machineFitAdvisory(.stt, workload: 1200)
    let fit = try #require(advisory.workload)
    #expect(!fit.withinCeiling)
    #expect(!advisory.fits)
    #expect(fit.projectedActivationBytes == 7_000)      // 1 000 + 5 × 1200, extrapolated
    #expect(advisory.machine.availableBytes > 7_000)    // the machine is not the reason
    #expect(advisory.message.contains("exceeds the declared measured ceiling"))
}

// Loud, not convenient: a package with no scaling cannot answer a workload question, and
// answering with the scalar would read as "fits" for a workload nobody measured.
@Test func askingAScalarOnlyPackageWithAWorkloadThrows() async throws {
    let engine = MLXServeEngine()
    let id = try await engine.register(
        PackageRegistration.of(ScalarSTTPackage.self),
        configuration: StandardConfiguration(weightsRepo: "mock/scalar"))
    do {
        _ = try await engine.machineFitAdvisory(.stt, package: id, workload: 60)
        Issue.record("expected activationScalingUndeclared")
    } catch {
        #expect(error as? EngineError == .activationScalingUndeclared(id))
    }
}

// The 1.36.0 scalar form is unchanged for a scalar-only package, and for a declaring package it
// carries the declaration and names the ceiling without evaluating any workload.
@Test func theScalarAdvisoryIsUnchangedAndNamesTheCeilingWhenDeclared() async throws {
    let engine = MLXServeEngine()
    let scalar = try await engine.register(
        PackageRegistration.of(ScalarSTTPackage.self),
        configuration: StandardConfiguration(weightsRepo: "mock/scalar"))
    let plain = try await engine.machineFitAdvisory(.stt, package: scalar)
    #expect(plain.workload == nil)
    #expect(plain.activationScaling == nil)
    #expect(!plain.message.contains("ceiling"))

    let scaling = try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                                            configuration: ScalingConfiguration())
    let declared = try await engine.machineFitAdvisory(.stt, package: scaling)
    #expect(declared.workload == nil)
    #expect(declared.activationScaling == quantScaling)
    #expect(declared.message.contains("holds up to 600 audioSeconds"))
}

// A host composes the question from what it holds: the same mapping admission uses.
@Test func workloadUnitsExposesTheConfigurationsMapping() async throws {
    let engine = MLXServeEngine()
    try await engine.register(PackageRegistration.of(ScalingSTTPackage.self),
                              configuration: ScalingConfiguration())
    let units = try await engine.workloadUnits(for: request(seconds: 42))
    #expect(units == 42)
    let advisory = try await engine.machineFitAdvisory(.stt, workload: try #require(units))
    #expect(advisory.workload?.projectedActivationBytes == 1_210)
}
