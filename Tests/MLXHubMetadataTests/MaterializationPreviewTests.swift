import XCTest
import MLXToolKit
@testable import MLXHubMetadata

/// A stub hub: fixed listings per repo, or a thrown error to model an unreachable hub.
private struct StubHub: HubMetadataProviding {
    var listings: [String: [HubFileEntry]] = [:]
    var failing: Set<String> = []

    func files(repo: String, revision: String?) async throws -> [HubFileEntry] {
        if failing.contains(repo) { throw HubMetadataError.httpStatus(404) }
        return listings[repo] ?? []
    }
}

/// MS-3 — size a pending materialization before any package code runs.
final class MaterializationPreviewTests: XCTestCase {

    private let hub = StubHub(listings: [
        "org/model": [
            HubFileEntry(path: "config.json", size: 1_000),
            HubFileEntry(path: "model.safetensors", size: 10_000),
            HubFileEntry(path: "model-bf16.safetensors", size: 40_000),
            HubFileEntry(path: "voices/af.safetensors", size: 500),
            HubFileEntry(path: "README.md", size: 7),
        ],
    ], failing: ["org/offline"])

    func testWholeListingSumsWhenNoGlobsAreDeclared() async throws {
        let bytes = try await MaterializationPreview.sizeOf(
            WeightSource(role: "main", repo: "org/model"), provider: hub)
        XCTAssertEqual(bytes, 51_507)
    }

    func testGlobsSelectOnlyTheDeclaredFiles() async throws {
        // The point of `matching`: a quantized configuration must NOT be charged for the 40 KB
        // bf16 sibling it never fetches.
        let bytes = try await MaterializationPreview.sizeOf(
            WeightSource(role: "main", repo: "org/model",
                         matching: ["config.json", "model.safetensors", "voices/*.safetensors"]),
            provider: hub)
        XCTAssertEqual(bytes, 11_500)
    }

    func testPreviewTotalsAcrossSourcesAndReportsFit() async throws {
        let preview = await MaterializationPreview.make(
            missing: [WeightSource(role: "main", repo: "org/model", matching: ["config.json"]),
                      WeightSource(role: "extra", repo: "org/model", matching: ["voices/*.safetensors"])],
            storeRoot: URL.temporaryDirectory,
            provider: hub)

        XCTAssertEqual(preview.sources.map(\.expectedBytes), [1_000, 500])
        XCTAssertEqual(preview.totalBytes, 1_500)
        XCTAssertNotNil(preview.freeBytes, "temp dir volume should report free space")
        XCTAssertEqual(preview.fits, true)
        XCTAssertFalse(preview.isSatisfied)
    }

    func testUnreachableHubDegradesToUnknownRatherThanZero() async {
        // A partial total would read as a safe-looking under-estimate — the whole total goes nil,
        // and `fits` with it, so a preview can never block a materialization.
        let preview = await MaterializationPreview.make(
            missing: [WeightSource(role: "main", repo: "org/model"),
                      WeightSource(role: "gated", repo: "org/offline")],
            storeRoot: URL.temporaryDirectory,
            provider: hub)

        XCTAssertEqual(preview.sources.map(\.expectedBytes), [51_507, nil])
        XCTAssertNil(preview.totalBytes)
        XCTAssertNil(preview.fits)
    }

    func testNothingMissingIsASatisfiedZeroCostPreview() async {
        let preview = await MaterializationPreview.make(missing: [], storeRoot: URL.temporaryDirectory,
                                                        provider: hub)
        XCTAssertTrue(preview.isSatisfied)
        XCTAssertEqual(preview.totalBytes, 0)
        XCTAssertEqual(preview.fits, true)
    }

    func testNoStoreRootMeansUnknownFreeSpace() async {
        let preview = await MaterializationPreview.make(
            missing: [WeightSource(role: "main", repo: "org/model")], storeRoot: nil, provider: hub)
        XCTAssertEqual(preview.totalBytes, 51_507)
        XCTAssertNil(preview.freeBytes)
        XCTAssertNil(preview.fits)
    }

    func testFitsIsFalseWhenTheDownloadExceedsFreeSpace() {
        let preview = MaterializationPreview(
            sources: [.init(role: "main", repo: "org/model", expectedBytes: 60_000_000_000)],
            totalBytes: 60_000_000_000, freeBytes: 40_000_000_000)
        XCTAssertEqual(preview.fits, false)
    }

    // MARK: - Live client parsing (no network)

    func testClientParsesATreeResponseAndSkipsDirectories() throws {
        let json = """
        [{"type":"directory","path":"voices","size":0},
         {"type":"file","path":"config.json","size":42},
         {"type":"file","path":"voices/af.safetensors","size":100}]
        """
        XCTAssertEqual(try HubMetadataClient.parseTree(Data(json.utf8)),
                       [HubFileEntry(path: "config.json", size: 42),
                        HubFileEntry(path: "voices/af.safetensors", size: 100)])
    }

    func testClientRejectsANonTreeBody() {
        XCTAssertThrowsError(try HubMetadataClient.parseTree(Data(#"{"error":"gated"}"#.utf8))) {
            XCTAssertEqual($0 as? HubMetadataError, .malformedResponse)
        }
    }
}
