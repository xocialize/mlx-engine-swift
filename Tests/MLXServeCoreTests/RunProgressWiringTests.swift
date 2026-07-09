import Testing
import MLXToolKit
@testable import MLXServeCore

// V2 (run-lifecycle program): the engine binds the ambient RunProgress sink around a package's
// run() and surfaces reports on the observable `runProgress` monitor, clearing on exit. All
// offline — no MLX kernels.

/// Cross-actor scratch the mock package writes its mid-run observations into.
private final class RunProgressProbe: @unchecked Sendable {
    static let shared = RunProgressProbe()
    var engine: MLXServeEngine?
    var sinkWasBound = false
    var midRunReport: RunPhaseReport?
    func reset(engine: MLXServeEngine) {
        self.engine = engine
        sinkWasBound = false
        midRunReport = nil
    }
}

@InferenceActor
private final class MockReportingPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "mock/mock", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .int4, residentBytes: 1)],
                requiredBackends: [.metalGPU]
            ),
            surfaces: [LLMContract.descriptor(name: "mock-llm", summary: "mock")]
        )
    }

    private var loaded = false
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }

    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        let probe = RunProgressProbe.shared
        // The engine must have bound the task-local sink around this call.
        probe.sinkWasBound = RunProgress.sink != nil
        RunProgress.report(.denoise, step: 2, totalSteps: 8)
        // The sink hops to the MainActor to write the monitor — poll until the report lands so
        // we can observe the monitor state MID-run (the entry is cleared once run() exits).
        if let engine = probe.engine {
            for _ in 0 ..< 200 {
                if let r = await MainActor.run(body: { engine.runProgress.report(for: .llm) }) {
                    probe.midRunReport = r
                    break
                }
                await Task.yield()
            }
        }
        return LLMResponse(text: "mock", finishReason: .stop)
    }
}

@Test func runBindsProgressSinkAndClearsOnExit() async throws {
    let engine = MLXServeEngine()
    RunProgressProbe.shared.reset(engine: engine)
    try await engine.register(PackageRegistration.of(MockReportingPackage.self),
                              configuration: StandardConfiguration(weightsRepo: "mock/mock"))
    _ = try await engine.run(LLMRequest(prompt: "hi"))

    // Sink was bound for the duration of run(), and the report reached the monitor mid-run.
    #expect(RunProgressProbe.shared.sinkWasBound)
    let mid = try #require(RunProgressProbe.shared.midRunReport)
    #expect(mid == RunPhaseReport(phase: .denoise, step: 2, totalSteps: 8))

    // After the run exits the entry clears (the defer's MainActor hop may lag — poll briefly).
    var cleared = false
    for _ in 0 ..< 200 {
        cleared = await MainActor.run { engine.runProgress.report(for: .llm) == nil }
        if cleared { break }
        await Task.yield()
    }
    #expect(cleared)
}

@Test func reportOutsideAnyRunIsNoOp() {
    // A package (or stray code path) reporting with no engine-bound sink must be harmless.
    RunProgress.report(.decode, step: 1, totalSteps: 3)
}
