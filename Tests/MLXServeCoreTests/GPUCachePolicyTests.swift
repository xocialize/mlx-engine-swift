import XCTest
import MLX
import MLXToolKit
@testable import MLXServeCore

/// N5: engine-owned GPU buffer-pool policy — config plumbing + telemetry. These touch the
/// PROCESS-GLOBAL MLX allocator settings (no kernels, no GPU work), so they live in one
/// XCTestCase (serial within the class) and every test sets the state it asserts on.
final class GPUCachePolicyTests: XCTestCase {

    private func device(totalGB: UInt64) -> DeviceProfile {
        DeviceProfile(
            chipTier: .max,
            macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
            backends: [.metalGPU],
            totalMemoryBytes: totalGB * 1_000_000_000)
    }

    /// The allocator getters initialize MLX's Metal device; in a runner process that can't
    /// load the bundled metallib the engine degrades to unmanaged (by design), so the
    /// tests asserting APPLIED limits skip rather than fail there.
    private func requireMLXAllocator() throws {
        guard (try? MLX.withError { _ = Memory.cacheLimit }) != nil else {
            throw XCTSkip("MLX Metal device unavailable in this test runner process")
        }
    }

    // MARK: - Policy math (pure)

    func testAutomaticIsMinOf2GBAnd5PercentOfBudget() {
        let auto = GPUCacheConfiguration()
        // Large budget (128 GB): the 2 GB arm wins.
        XCTAssertEqual(auto.resolvedLimitBytes(budgetBytes: 128_000_000_000), 2_147_483_648)
        // Small budget (10 GB): the 5% arm wins (500 MB).
        XCTAssertEqual(auto.resolvedLimitBytes(budgetBytes: 10_000_000_000), 500_000_000)
        // Crossover: 5% of ~43 GB ≈ 2.15 GB > 2 GB cap.
        XCTAssertEqual(auto.resolvedLimitBytes(budgetBytes: 43_000_000_000), 2_147_483_648)
    }

    func testFixedAndUnmanagedResolution() {
        XCTAssertEqual(GPUCacheConfiguration(limit: .bytes(123)).resolvedLimitBytes(budgetBytes: 1), 123)
        // 0 = recycling disabled, still a managed write.
        XCTAssertEqual(GPUCacheConfiguration(limit: .bytes(0)).resolvedLimitBytes(budgetBytes: 1), 0)
        XCTAssertNil(GPUCacheConfiguration.unmanaged.resolvedLimitBytes(budgetBytes: 128_000_000_000))
    }

    func testTrimKnobsDefaultOff() {
        let config = GPUCacheConfiguration()
        XCTAssertFalse(config.trimAfterEvict)
        XCTAssertNil(config.trimEveryRuns)
    }

    // MARK: - Engine init applies the limit (process-global, allocator API only)

    func testEngineInitAppliesAutomaticLimit() async throws {
        try requireMLXAllocator()
        // 20 GB budget → 5% arm → 1 GB.
        let governor = MemoryGovernor(budgetBytes: 20_000_000_000)
        let engine = MLXServeEngine(device: device(totalGB: 64), governor: governor)
        XCTAssertEqual(Memory.cacheLimit, 1_000_000_000)
        let applied = await engine.appliedGPUCacheLimitBytes
        XCTAssertEqual(applied, 1_000_000_000)
    }

    func testEngineInitAppliesFixedLimit() throws {
        try requireMLXAllocator()
        _ = MLXServeEngine(
            device: device(totalGB: 64),
            governor: MemoryGovernor(budgetBytes: 20_000_000_000),
            gpuCache: GPUCacheConfiguration(limit: .bytes(777_000_000)))
        XCTAssertEqual(Memory.cacheLimit, 777_000_000)
    }

    func testUnmanagedLeavesHostSetLimitUntouched() async throws {
        try requireMLXAllocator()
        // Host sets its own limit BEFORE constructing the engine; .unmanaged must not clobber.
        Memory.cacheLimit = 555_000_000
        let engine = MLXServeEngine(
            device: device(totalGB: 64),
            governor: MemoryGovernor(budgetBytes: 20_000_000_000),
            gpuCache: .unmanaged)
        XCTAssertEqual(Memory.cacheLimit, 555_000_000)
        let applied = await engine.appliedGPUCacheLimitBytes
        XCTAssertNil(applied)
    }

    func testManagedOverwritesEarlierHostWrite() throws {
        try requireMLXAllocator()
        // Documented precedence: last write wins — a pre-engine host write is superseded by
        // the engine's managed policy (the MLXCompanion workaround becomes redundant).
        Memory.cacheLimit = 555_000_000
        _ = MLXServeEngine(
            device: device(totalGB: 64),
            governor: MemoryGovernor(budgetBytes: 40_000_000_000))
        XCTAssertEqual(Memory.cacheLimit, 2_000_000_000)  // 5% of 40 GB
    }

    // MARK: - Telemetry + trim

    func testGPUPoolSnapshotReflectsEffectiveLimit() throws {
        try requireMLXAllocator()
        let engine = MLXServeEngine(
            device: device(totalGB: 64),
            governor: MemoryGovernor(budgetBytes: 20_000_000_000),
            gpuCache: GPUCacheConfiguration(limit: .bytes(888_000_000)))
        let snap = try XCTUnwrap(engine.gpuPoolSnapshot())
        XCTAssertEqual(snap.cacheLimitBytes, 888_000_000)
        // No GPU work has necessarily run in this process — just require sane readings.
        XCTAssertGreaterThanOrEqual(snap.peakBytes, snap.activeBytes > 0 ? 1 : 0)
        XCTAssertTrue(snap.description.contains("limit"))
    }

    func testTrimCachesDoesNotGrowThePool() throws {
        try requireMLXAllocator()
        let engine = MLXServeEngine(
            device: device(totalGB: 64),
            governor: MemoryGovernor(budgetBytes: 20_000_000_000))
        let before = try XCTUnwrap(engine.gpuPoolSnapshot()).cacheBytes
        engine.trimCaches()
        XCTAssertLessThanOrEqual(try XCTUnwrap(engine.gpuPoolSnapshot()).cacheBytes, before)
    }

    func testConfiguredPolicyIsReadable() {
        let config = GPUCacheConfiguration(
            limit: .bytes(1), trimAfterEvict: true, trimEveryRuns: 4)
        let engine = MLXServeEngine(
            device: device(totalGB: 64),
            governor: MemoryGovernor(budgetBytes: 20_000_000_000),
            gpuCache: config)
        XCTAssertEqual(engine.gpuCachePolicy, config)
        XCTAssertEqual(engine.gpuCachePolicy.trimEveryRuns, 4)
        XCTAssertTrue(engine.gpuCachePolicy.trimAfterEvict)
    }
}
