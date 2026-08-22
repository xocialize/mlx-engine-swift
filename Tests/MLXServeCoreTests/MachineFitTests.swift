import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - 1.36.0 machine-wide fit + pressure (AB-A-0014)

private struct FitConfiguration: PackageConfiguration, QuantConfigured, FootprintConfigured {
    var projectedResident: UInt64
    var quant: Quant { .bf16 }
    var residentBytesHint: UInt64? { projectedResident }
}

@InferenceActor
private final class FitPackage: ModelPackage {
    typealias Configuration = FitConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/fit", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                requiredBackends: [.metalGPU]),
            surfaces: [LLMContract.descriptor(name: "fit-llm", summary: "mock")])
    }
    nonisolated init(configuration: FitConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "mock", finishReason: .stop)
    }
}

@Test func machineMemoryReadsSaneNumbers() throws {
    let m = try #require(HostMemory.machineMemory())
    #expect(m.totalBytes > 0)
    #expect(m.freeBytes > 0)                       // an entirely full machine would not run tests
    #expect(m.availableBytes >= m.freeBytes)       // available = free + inactive, by definition
    #expect(m.freeBytes < m.totalBytes)
    #expect(m.wiredBytes > 0)                      // the kernel always wires something
}

@Test func tinyProjectionFits() async throws {
    let engine = MLXServeEngine()
    let id = try await engine.register(PackageRegistration.of(FitPackage.self),
                                       configuration: FitConfiguration(projectedResident: 1))
    let advisory = try await engine.machineFitAdvisory(.llm, package: id)
    #expect(advisory.fits)
    #expect(advisory.machine.totalBytes > 0)
    #expect(advisory.message.contains("GB"))
}

@Test func absurdProjectionDoesNotFit_andTheArithmeticIsAdditional() async throws {
    // 1 EB projected: no machine has it. The advisory must say so via the ADDITIONAL arithmetic
    // (projected − current), and stay a value, not a throw — AB-D-0038: the host decides.
    let engine = MLXServeEngine()
    let id = try await engine.register(
        PackageRegistration.of(FitPackage.self),
        configuration: FitConfiguration(projectedResident: 1 << 60))
    let advisory = try await engine.machineFitAdvisory(.llm, package: id)
    #expect(!advisory.fits)
    #expect(advisory.projectedPeakBytes >= 1 << 60)
    #expect(advisory.additionalBytes <= advisory.projectedPeakBytes)
    #expect(advisory.additionalBytes >= advisory.projectedPeakBytes - advisory.currentProcessBytes)
    #expect(advisory.message.contains("available"))
}

@Test func pressureEventsReachEverySubscriber() async throws {
    let engine = MLXServeEngine()
    let streamA = await engine.memoryPressureEvents()
    let streamB = await engine.memoryPressureEvents()
    let event = MemoryPressureEvent(level: .warning, machine: HostMemory.machineMemory())
    await engine._injectMemoryPressure(event)
    var iterA = streamA.makeAsyncIterator()
    var iterB = streamB.makeAsyncIterator()
    let a = await iterA.next()
    let b = await iterB.next()
    #expect(a?.level == .warning)
    #expect(b?.level == .warning)
    #expect(a?.machine != nil)   // the reading rides the event — the overlay needs the numbers
}
