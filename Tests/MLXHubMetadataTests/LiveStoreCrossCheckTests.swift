import XCTest
import MLXToolKit
@testable import MLXHubMetadata

/// MS-3's outstanding verification: does the hub **tree-API sum** actually agree with what lands
/// **on disk**? Everything else about MS-3 is offline-proven with mocks, which cannot catch a wrong
/// endpoint, a glob that matches the wrong files, or LFS entries whose reported size is the pointer
/// rather than the payload.
///
/// **Opt-in, never in CI.** It needs the network and a populated store, so it skips unless a store
/// root is supplied:
///
/// ```bash
/// MLXENGINE_LIVE_STORE_ROOT=/Volumes/Satechi/Models \
///   swift test --build-system swiftbuild --filter LiveStoreCrossCheck
/// ```
///
/// It reads only public metadata and never writes or downloads anything.
final class LiveStoreCrossCheckTests: XCTestCase {

    private func storeRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MLXENGINE_LIVE_STORE_ROOT"],
              !path.isEmpty else {
            throw XCTSkip("Set MLXENGINE_LIVE_STORE_ROOT to a populated model store to run this.")
        }
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("MLXENGINE_LIVE_STORE_ROOT does not exist: \(path)")
        }
        return url
    }

    /// For the smallest materialized repo in the store, the tree-API sum should land within a few
    /// percent of the snapshot's on-disk size.
    ///
    /// Exact equality is the wrong bar and would make this test lie: on-disk figures are **allocated**
    /// bytes (block-rounded up, so a repo of many small files reads high), the hub reports **logical**
    /// bytes, and the local snapshot may be pinned to an older revision than `main`. A few percent is
    /// the signal we want — an order-of-magnitude gap is the bug this test exists to catch.
    ///
    /// One known limitation: this sums the **whole** repo listing while the engine may have
    /// materialized only the files a source's `matching` globs selected. The two agree when the
    /// weight shards dominate (measured 2026-07-26: 1.0004 on a 419 MB codec repo whose 6 hub files
    /// are one shard plus configs). A repo carrying a large *unmatched* file would diverge here
    /// without anything being wrong — check the glob set before believing a failure.
    func testTreeAPISumMatchesOnDiskSizeForTheSmallestRepo() async throws {
        let root = try storeRoot()
        let installed = ModelStore.installedModels(at: root).filter(\.hasMarker)
        try XCTSkipIf(installed.isEmpty, "No marked repos in \(root.path).")

        let target = try XCTUnwrap(installed.min { $0.bytes < $1.bytes })
        let store = ModelStore(root: root)

        // A store root legitimately holds **two** layouts, and a nil snapshot is normal rather than
        // broken: the hub client writes `models--org--name/{refs,snapshots,blobs}`, while the
        // engine's own materializer (contract 1.24) lands files FLAT in `models--org--name/`. Size
        // whichever this repo actually is — the MS-2 probe accepts both for the same reason.
        let snapshot = store.snapshotDirectory(for: target.repo)
        let measured = try snapshot ?? XCTUnwrap(store.directory(for: target.repo))
        let layout = snapshot == nil ? "flat (engine)" : "hub snapshot"

        // On-disk truth (dedupes the blobs/ links the nested HF layout uses).
        let onDisk = ModelStore.usage(at: measured).bytes
        // What MS-3's own sizing path reports for the whole repo listing.
        let entries = try await HubMetadataClient().files(repo: target.repo, revision: nil)
        try XCTSkipIf(entries.isEmpty, "Hub returned no listing for \(target.repo) — offline?")
        let hubTotal = entries.reduce(UInt64(0)) { $0 + $1.size }

        let ratio = Double(hubTotal) / Double(max(onDisk, 1))
        print("""
        [MS-3 cross-check] \(target.repo)
          layout                        : \(layout)
          on-disk (allocated)           : \(onDisk) bytes
          tree-API sum  (logical, repo) : \(hubTotal) bytes  over \(entries.count) files
          ratio hub/disk                : \(String(format: "%.4f", ratio))
        """)

        XCTAssertGreaterThan(hubTotal, 0, "tree API reported a zero total — wrong endpoint or field")
        XCTAssertEqual(ratio, 1.0, accuracy: 0.05,
                       "tree-API sum and on-disk size disagree by more than 5% for \(target.repo)")
    }

    /// The weight files specifically must not be LFS-pointer-sized — the classic way a hub listing
    /// under-reports by ~4 orders of magnitude and a disk precheck waves through a download that
    /// cannot fit.
    func testWeightEntriesReportPayloadSizesNotPointerSizes() async throws {
        let root = try storeRoot()
        let installed = ModelStore.installedModels(at: root).filter(\.hasMarker)
        try XCTSkipIf(installed.isEmpty, "No marked repos in \(root.path).")
        let target = try XCTUnwrap(installed.min { $0.bytes < $1.bytes })

        let entries = try await HubMetadataClient().files(repo: target.repo, revision: nil)
        try XCTSkipIf(entries.isEmpty, "Hub returned no listing for \(target.repo) — offline?")
        let weights = entries.filter { $0.path.hasSuffix(".safetensors") }
        try XCTSkipIf(weights.isEmpty, "\(target.repo) declares no .safetensors entries.")

        for entry in weights {
            // An LFS pointer file is ~130 bytes; any real weight shard is orders above that.
            XCTAssertGreaterThan(entry.size, 100_000,
                                 "\(entry.path) reported \(entry.size) bytes — looks like an LFS pointer")
        }
    }
}
