import XCTest
@testable import MLXServeConformance
import MLXToolKit

// The CAN gate (CancellationConformance) proven against cooperative and misbehaving mock
// packages — the same harness-proof role the MAT mocks play for MaterializationConformance.
// All offline: the pre-cancelled form never reaches weights, so no MLX kernels run.

// MARK: - Mock manifest

private func mockManifest(capability: Capability,
                          peakActivationBytes: UInt64 = 0) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/can", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 1_000_000,
                                        peakActivationBytes: peakActivationBytes)],
            requiredBackends: [.metalGPU]
        ),
        surfaces: [ToolDescriptor(name: "mock", capability: capability, summary: "mock")]
    )
}

// MARK: - Mock packages

/// The required shape: `try Task.checkCancellation()` is the first act of `run()`.
@InferenceActor private final class CooperativePackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        try Task.checkCancellation()
        return LLMResponse(text: "full", finishReason: .stop)
    }
}

/// The signature failure: validation before cancellation (the doc-comment-only era shape).
@InferenceActor private final class ValidationFirstPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        throw PackageError.notLoaded   // never looked at Task.isCancelled
    }
}

/// Ignores cancellation entirely and completes (the Qwen3-TTS Talker-loop failure mode,
/// collapsed to its offline essence).
@InferenceActor private final class IgnoringPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "done", finishReason: .stop)
    }
}

/// Notices the cancellation but launders it into a package error — breaks the engine's lane
/// disambiguation and the caller's `.cancelled` classification.
@InferenceActor private final class LaunderingPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        do {
            try Task.checkCancellation()
        } catch {
            throw PackageError.unsupportedRequestFeature("cancelled mid-run")
        }
        return LLMResponse(text: "full", finishReason: .stop)
    }
}

/// Absorbs cancellation into a cancelled-marked partial response (the sanctioned alternative
/// for capabilities whose response shape carries a finish reason).
@InferenceActor private final class AbsorbingPackage: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm) }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        if Task.isCancelled {
            return LLMResponse(text: "partial", finishReason: .cancelled)
        }
        return LLMResponse(text: "full", finishReason: .stop)
    }
}

// MARK: - CAN-1 / CAN-2

final class CancellationRunConformanceTests: XCTestCase {

    private let request = LLMRequest(prompt: "probe")

    private func can(_ report: CancellationConformance.Report,
                     _ prefix: String) -> CancellationConformance.Check {
        report.checks.first { $0.name.hasPrefix(prefix) }!
    }

    func testCooperativePackagePasses() async {
        let report = await CancellationConformance.checkRun(
            package: CooperativePackage(configuration: StandardConfiguration(weightsRepo: "mock/can")),
            request: request)
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.checks.count, 2)
    }

    func testValidationFirstPackageFailsCAN1WithEntryCheckpointNote() async {
        let report = await CancellationConformance.checkRun(
            package: ValidationFirstPackage(configuration: StandardConfiguration(weightsRepo: "mock/can")),
            request: request)
        XCTAssertFalse(report.passed)
        let can1 = can(report, "CAN-1")
        XCTAssertFalse(can1.passed)
        XCTAssertTrue(can1.note.contains("entry checkpoint")
                        || can1.note.contains("notLoaded"), can1.note)
    }

    func testIgnoringPackageFailsCAN1() async {
        let report = await CancellationConformance.checkRun(
            package: IgnoringPackage(configuration: StandardConfiguration(weightsRepo: "mock/can")),
            request: request)
        XCTAssertFalse(report.passed)
        XCTAssertFalse(can(report, "CAN-1").passed)
        XCTAssertTrue(can(report, "CAN-1").note.contains("ignored"))
    }

    func testLaunderingPackageFailsCAN2NamingTheType() async {
        let report = await CancellationConformance.checkRun(
            package: LaunderingPackage(configuration: StandardConfiguration(weightsRepo: "mock/can")),
            request: request)
        XCTAssertFalse(report.passed)
        let can2 = can(report, "CAN-2")
        XCTAssertFalse(can2.passed)
        XCTAssertTrue(can2.note.contains("laundered"), can2.note)
        XCTAssertTrue(can2.note.contains("PackageError"), can2.note)
    }

    func testAbsorbingPackagePassesWithClassifier() async {
        let report = await CancellationConformance.checkRun(
            package: AbsorbingPackage(configuration: StandardConfiguration(weightsRepo: "mock/can")),
            request: request,
            classifiesCancelled: { ($0 as? LLMResponse)?.finishReason == .cancelled })
        XCTAssertTrue(report.passed, report.summary)
    }

    func testAbsorbingPackageFailsWithoutClassifier() async {
        // Without the classifier the harness cannot credit the marked response — returning
        // any response from a cancelled run must be explicitly proven, never assumed.
        let report = await CancellationConformance.checkRun(
            package: AbsorbingPackage(configuration: StandardConfiguration(weightsRepo: "mock/can")),
            request: request)
        XCTAssertFalse(report.passed)
    }
}

// MARK: - CAN-3

final class CancellationCadenceConformanceTests: XCTestCase {

    func testLongRunImpliedByCapabilityAndByActivation() {
        XCTAssertTrue(CancellationConformance.longRunImplied(
            by: mockManifest(capability: .tts)))
        XCTAssertTrue(CancellationConformance.longRunImplied(
            by: mockManifest(capability: .imageRestore, peakActivationBytes: 4_000_000_000)))
        XCTAssertFalse(CancellationConformance.longRunImplied(
            by: mockManifest(capability: .imageRestore)))
    }

    func testLongRunPackageWithCadencePasses() {
        let report = CancellationConformance.checkCadence(
            manifest: mockManifest(capability: .textToVideo),
            posture: .cadence([
                .init(phase: .denoise, unit: .step, reportsRunProgress: true),
                .init(phase: .decode, unit: .chunk),
            ]))
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertTrue(report.checks[0].note.contains("denoise/step"))
        XCTAssertTrue(report.checks[0].note.contains("RunProgress-evidenced"))
    }

    func testLongRunPackageClaimingSubSecondFails() {
        for manifest in [mockManifest(capability: .tts),
                         mockManifest(capability: .imageRestore,
                                      peakActivationBytes: 4_000_000_000)] {
            let report = CancellationConformance.checkCadence(
                manifest: manifest, posture: .subSecondRuns(reason: "it feels fast"))
            XCTAssertFalse(report.passed, report.summary)
        }
    }

    func testShortRunPackageSubSecondExemptionPassesWithReason() {
        let report = CancellationConformance.checkCadence(
            manifest: mockManifest(capability: .imageRestore),
            posture: .subSecondRuns(reason: "single forward pass, one MLX eval"))
        XCTAssertTrue(report.passed, report.summary)

        let unreasoned = CancellationConformance.checkCadence(
            manifest: mockManifest(capability: .imageRestore),
            posture: .subSecondRuns(reason: ""))
        XCTAssertFalse(unreasoned.passed)
    }

    func testEmptyCadenceDeclarationFails() {
        let report = CancellationConformance.checkCadence(
            manifest: mockManifest(capability: .textToVideo), posture: .cadence([]))
        XCTAssertFalse(report.passed)
    }
}
