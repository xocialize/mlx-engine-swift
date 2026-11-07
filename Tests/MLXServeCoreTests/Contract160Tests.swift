//
//  Contract160Tests.swift
//  MLXServeCoreTests
//
//  Contract 1.60.0 — the worker report carries external tenants (AB-A-0210), a package can declare
//  process-environment requirements (AB-A-0215), Quant gains mxfp8 / nvfp4 (AB-A-0204), the
//  release constant (AB-A-0248) and the preview's per-source failure (AB-A-0153). Offline.
//

import Foundation
import Testing
import MLXToolKit
import MLXHubMetadata
@testable import MLXServeCore

private struct EnvConfiguration: PackageConfiguration {}

@InferenceActor
private final class EnvPackage: ModelPackage {
    typealias Configuration = EnvConfiguration
    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
            provenance: Provenance(sourceRepo: "org/env", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .int4, residentBytes: 10, peakActivationBytes: 5)],
                requiredBackends: [.metalGPU],
                processEnvironment: ["MLX_ENGINE_TEST_ENV_UNSET": "0", "MLX_ENGINE_TEST_ENV_SET": "0"]),
            surfaces: [T2IContract.descriptor(name: "env-t2i", summary: "mock")])
    }
    nonisolated init(configuration: EnvConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        T2IResponse(image: Image(format: .png, data: Data([1])))
    }
}

@Test func theWorkerReportCarriesTheExternalTenants() async throws {
    let engine = MLXServeEngine(governor: MemoryGovernor(budgetBytes: 10_000), physFootprint: { 0 })
    let tenant = await engine.registerExternalTenant(id: "matmul", persistentBytes: 300, transientBytes: 200)
    let report = await engine.workerMemoryReport()
    #expect(report.externalTenants == ["matmul": ExternalTenantCharge(persistentBytes: 300, transientBytes: 200)])
    #expect(report.externalBytes == 500)
    #expect(report.residentBytes == 0)
    #expect(report.availableBytes == 9_500)
    let round = try JSONDecoder().decode(WorkerMemoryReport.self, from: JSONEncoder().encode(report))
    #expect(round == report)
    tenant.withdraw()
    #expect(await engine.workerMemoryReport().externalTenants == [:])
}

@Test func aPre160ReportDecodesWithNilExternals() throws {
    let report = WorkerMemoryReport(budgetBytes: 1, residentBytes: 0, transientReserveBytes: 0,
                                    availableBytes: 1, physFootprintBytes: nil, gpuActiveBytes: nil,
                                    gpuCacheBytes: nil, residents: [:], running: [])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    object.removeValue(forKey: "externalTenants")
    object.removeValue(forKey: "externalBytes")
    let old = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(WorkerMemoryReport.self, from: old)
    #expect(decoded.externalTenants == nil)
    #expect(decoded.externalBytes == nil)
}

@Test func registerAppliesDeclaredProcessEnvironmentAndRecordsConflicts() async throws {
    unsetenv("MLX_ENGINE_TEST_ENV_UNSET")
    setenv("MLX_ENGINE_TEST_ENV_SET", "1", 1)
    defer { unsetenv("MLX_ENGINE_TEST_ENV_UNSET"); unsetenv("MLX_ENGINE_TEST_ENV_SET") }
    let engine = MLXServeEngine(governor: MemoryGovernor(budgetBytes: 10_000), physFootprint: { 0 })
    try await engine.register(PackageRegistration.of(EnvPackage.self), configuration: EnvConfiguration())
    #expect(String(cString: getenv("MLX_ENGINE_TEST_ENV_UNSET")) == "0", "set when the process had not")
    #expect(String(cString: getenv("MLX_ENGINE_TEST_ENV_SET")) == "1", "a host's value is never overridden")
    let findings = await engine.processEnvironmentFindings
    #expect(findings == [ProcessEnvironmentFinding(name: "MLX_ENGINE_TEST_ENV_SET", required: "0",
                                                   actual: "1", requiredBy: "org/env")])
}

@Test func aManifestWithoutProcessEnvironmentDecodes() throws {
    let manifest = RequirementsManifest(footprints: [], requiredBackends: [.metalGPU])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    object.removeValue(forKey: "processEnvironment")
    let decoded = try JSONDecoder().decode(RequirementsManifest.self,
                                           from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.processEnvironment == [:])
}

@Test func theNewQuantsRankWithTheirBitWidth() throws {
    #expect(Quant.mxfp8.meets(floor: .int8))
    #expect(!Quant.mxfp8.meets(floor: .fp16))
    #expect(Quant.nvfp4.meets(floor: .int4))
    #expect(!Quant.nvfp4.meets(floor: .int5))
    #expect(Quant.allCases.contains(.mxfp8) && Quant.allCases.contains(.nvfp4))
    let decoded = try JSONDecoder().decode(Quant.self, from: Data("\"mxfp8\"".utf8))
    #expect(decoded == .mxfp8)
}

@Test func theReleaseConstantNamesTheLinkedEngine() {
    #expect(MLXEngineRelease.version.split(separator: ".").count == 3)
    #expect(MLXEngineRelease.contract == ContractVersion.current.description)
}

@Test func hi3dIsAllowlistedWithItsDisplayString() {
    #expect(SPDXLicense.hi3dOpen1_0.identifier == "LicenseRef-Hi3D-Open-1.0")
    #expect(SPDXLicense.hi3dOpen1_0.isPermissive)
    #expect(SPDXLicense.hi3dOpen1_0.requiredDisplayText == "Powered by Hi3D 1.0")
    #expect(LicensePolicy.permissiveOnly.evaluate(
        LicenseDeclaration(weightLicense: .hi3dOpen1_0, portCodeLicense: .mit)) == .admitted)
}

private struct DownHub: HubMetadataProviding {
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] {
        throw HubMetadataError.httpStatus(404)
    }
}

@Test func thePreviewNamesWhyASourceCouldNotBeSized() async {
    let preview = await MaterializationPreview.make(
        missing: [WeightSource(role: "main", repo: "org/never", revision: "v2")],
        storeRoot: nil, provider: DownHub())
    let source = preview.sources[0]
    #expect(source.expectedBytes == nil)
    #expect(source.revision == "v2")
    #expect(source.failureStatus == 404)
    #expect(source.failure?.contains("does not exist") == true)
    #expect(HubMetadataError.httpStatus(404).localizedDescription.contains("404"))
}
