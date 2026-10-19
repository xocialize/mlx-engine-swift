import XCTest
@testable import MLXServeConformance
import MLXToolKit

// The ADP gate (AdapterConformance, contract 1.53.0) proven against coherent, incoherent,
// unadvertised, unbindable and mismatched-catalog declarations.

private let support = AdapterSupport(baseModel: "klein-4b", formats: [.bflFused, .diffusersPEFT],
                                     kinds: [.plain, .referenceConditioned], maxCount: 2)

private func manifest(_ surfaces: [ToolDescriptor]) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/adp", revision: "main", tier: 1),
        requirements: RequirementsManifest(footprints: [QuantFootprint(quant: .bf16, residentBytes: 1)],
                                           requiredBackends: [.metalGPU]),
        surfaces: surfaces)
}

private func adapter(_ id: String, base: String = "klein-4b", capability: Capability = .textToImage,
                     revision: String = String(repeating: "a", count: 40)) -> AdapterDescriptor {
    AdapterDescriptor(id: id, format: .bflFused, baseModels: [base], capabilities: [capability],
                      source: AdapterSource(repo: "org/\(id)", revision: revision,
                                            file: "\(id).safetensors",
                                            sha256: String(repeating: "f", count: 64)),
                      license: .apache2)
}

private struct PlainConfig: PackageConfiguration {}
private struct BindableConfig: PackageConfiguration, AdapterConfigured {
    var loadedAdapters: [ResolvedAdapter] = []
}

final class AdapterConformanceTests: XCTestCase {

    private func passed(_ report: AdapterConformance.Report, _ prefix: String) -> [Bool] {
        report.checks.filter { $0.name.hasPrefix(prefix) }.map(\.passed)
    }

    func testAManifestWithoutAdaptersPassesVacuously() {
        let report = AdapterConformance.check(manifest: manifest([T2IContract.descriptor(name: "t", summary: "s")]))
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(passed(report, "ADP-0"), [true])
    }

    func testACoherentDeclarationAndCatalogPass() {
        let surfaces = [
            T2IContract.descriptor(name: "t2i", summary: "s").declaring(adapters: support),
            IEditContract.descriptor(name: "edit", summary: "s").declaring(adapters: support),
        ]
        let report = AdapterConformance.check(manifest: manifest(surfaces), configuration: PlainConfig(),
                                              catalog: [adapter("anime"), adapter("pose", capability: .imageEdit)])
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(passed(report, "ADP-1"), [true, true])
        XCTAssertEqual(passed(report, "ADP-2"), [true, true])
        XCTAssertEqual(passed(report, "ADP-4"), [true, true])
        XCTAssertTrue(passed(report, "ADP-3").isEmpty)           // per-request: nothing to bind
    }

    func testIncoherentAndMisplacedDeclarationsFailADP1() {
        let broken = AdapterSupport(baseModel: "", formats: [], maxCount: 0)
        let surfaces = [
            T2IContract.descriptor(name: "t2i", summary: "s").declaring(adapters: broken),
            LLMContract.descriptor(name: "llm", summary: "s").declaring(adapters: support),
        ]
        let report = AdapterConformance.check(manifest: manifest(surfaces))
        XCTAssertFalse(report.passed)
        XCTAssertEqual(passed(report, "ADP-1"), [false, false])
        XCTAssertTrue(report.summary.contains("carries no adapters"), report.summary)
    }

    func testDeclaringWithoutAdvertisingFailsADP2AndViceVersa() {
        // Built through the initializer: declared, but the parameter was never added.
        let unadvertised = ToolDescriptor(name: "quiet", capability: .textToImage, summary: "s",
                                          adapters: support)
        let advertisedOnly = ToolDescriptor(
            name: "loud", capability: .textToImage, summary: "s",
            parameters: [ParameterSchema(name: "adapters", kind: .array, required: false)])
        let report = AdapterConformance.check(manifest: manifest([unadvertised, advertisedOnly]))
        XCTAssertEqual(passed(report, "ADP-2"), [false, false])
    }

    func testALoadTimeSurfaceNeedsAnAdapterConfiguredConfiguration() {
        let loadTime = AdapterSupport(baseModel: "klein-4b", formats: [.bflFused], binding: .loadTime)
        let surfaces = [T2IContract.descriptor(name: "t2i", summary: "s").declaring(adapters: loadTime)]
        XCTAssertEqual(passed(AdapterConformance.check(manifest: manifest(surfaces),
                                                       configuration: BindableConfig()), "ADP-3"), [true])
        XCTAssertEqual(passed(AdapterConformance.check(manifest: manifest(surfaces),
                                                       configuration: PlainConfig()), "ADP-3"), [false])
        XCTAssertEqual(passed(AdapterConformance.check(manifest: manifest(surfaces)), "ADP-3"), [false])
    }

    func testACatalogEntryThatIsUnpinnedOrFitsNothingFailsADP4() {
        let surfaces = [T2IContract.descriptor(name: "t2i", summary: "s").declaring(adapters: support)]
        let report = AdapterConformance.check(
            manifest: manifest(surfaces),
            catalog: [adapter("floating", revision: "main"), adapter("qwen-style", base: "qwen-image")])
        XCTAssertEqual(passed(report, "ADP-4"), [false, false])
        XCTAssertTrue(report.summary.contains("40-character commit hash"), report.summary)
        XCTAssertTrue(report.summary.contains("not this surface's base model klein-4b"), report.summary)

        let noSurface = AdapterConformance.check(manifest: manifest([T2IContract.descriptor(name: "t", summary: "s")]),
                                                 catalog: [adapter("anime")])
        XCTAssertFalse(noSurface.passed)
        XCTAssertTrue(noSurface.summary.contains("none declares AdapterSupport"), noSurface.summary)
    }
}
