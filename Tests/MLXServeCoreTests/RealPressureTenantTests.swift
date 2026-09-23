//
//  RealPressureTenantTests.swift
//  MLXServeCoreTests
//
//  Contract 1.44.0 — the R-MEM-1 real-pressure pass asks external tenants to shrink BEFORE it
//  evicts an idle resident, and credits their DECLARED drop against a `phys_footprint` reading
//  that has not caught up yet (AB-A-0093; measured on a 24 GB M5 Pro in AB-R-0299: a canvas
//  tenant could shed 852 MB in 0.04 ms but R-MEM-1 never asked it). Offline, mock packages, a
//  mocked real reading, no MLX, no GPU.
//
//  Budget 1 000 B, high-watermark 0.85 → R-MEM-1 ceiling 850 B. Every package here is 200 B
//  persistent + 0 transient and the tenant declares 300 B, so the DECLARED accounting always fits
//  (≤ 900 B) and only the mocked real reading drives the pass.
//

import Foundation
import Synchronization
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private let budget: UInt64 = 1_000

/// Ordered record of shrink requests and package unloads, shared across packages and handlers.
/// Configurations are `Codable`, so a package finds its test's log by id through `EventLog.live`.
private final class EventLog: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var _events: [String] = []
    init() { Self.registry.withLock { $0[id] = self } }
    static func live(_ id: UUID) -> EventLog? { registry.withLock { $0[id] } }
    private static let registry = Mutex<[UUID: EventLog]>([:])
    func note(_ event: String) { lock.withLock { _events.append(event) } }
    var events: [String] { lock.withLock { _events } }
    var shrinks: [String] { events.filter { $0.hasPrefix("shrink") } }
    var unloads: [String] { events.filter { $0.hasPrefix("unload") } }
}

/// The mocked `phys_footprint`: a fixed reading (the lag case — it does NOT drop when a tenant
/// sheds), optionally a single armed high reading, and a count of reads.
private final class RealMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64?
    private var _armed: UInt64?
    private var _reads = 0
    init(_ value: UInt64?) { _value = value }
    func set(_ value: UInt64?) { lock.withLock { _value = value } }
    /// The next read returns `value` once, then the fixed reading resumes.
    func armOnce(_ value: UInt64) { lock.withLock { _armed = value } }
    func read() -> UInt64? {
        lock.withLock {
            _reads += 1
            if let armed = _armed { _armed = nil; return armed }
            return _value
        }
    }
    var reads: Int { lock.withLock { _reads } }
}

private func engine(_ real: RealMemory, shrinkTimeout: Duration = .seconds(2)) -> MLXServeEngine {
    MLXServeEngine(governor: MemoryGovernor(budgetBytes: budget),
                   externalTenants: ExternalTenantPolicy(shrinkTimeout: shrinkTimeout),
                   physFootprint: { real.read() })
}

private func mockManifest(name: String) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 200, peakActivationBytes: 0)],
            requiredBackends: [.metalGPU]),
        surfaces: [ToolDescriptor(name: name, capability: .llm, summary: "mock")])
}

/// 200 B persistent, logs its unload to `log` under its package id.
@InferenceActor private final class LoggedLLM: ModelPackage {
    typealias Configuration = LoggedConfiguration
    nonisolated static var manifest: PackageManifest { mockManifest(name: "logged-llm") }
    private let configuration: LoggedConfiguration
    nonisolated init(configuration: LoggedConfiguration) { self.configuration = configuration }
    func load() async throws {}
    func unload() async { EventLog.live(configuration.log)?.note("unload:\(configuration.name)") }
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: configuration.name, finishReason: .stop)
    }
}

private struct LoggedConfiguration: PackageConfiguration {
    let name: String
    let log: UUID
    var weightsRepo: String { "mock/\(name)" }
}

private func register(_ engine: MLXServeEngine, _ name: String, log: EventLog) async throws {
    try await engine.register(PackageRegistration.of(LoggedLLM.self),
                              configuration: LoggedConfiguration(name: name, log: log.id),
                              id: PackageID(name))
}

/// A 300 B tenant whose handler logs the request, then declares `keeps` bytes.
private func canvas(_ engine: MLXServeEngine, log: EventLog, keeps: UInt64,
                    persistent: UInt64 = 300) async -> ExternalTenant {
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: persistent)
    tenant.setShrinkHandler { [weak tenant] requested in
        log.note("shrink:\(requested)")
        tenant?.update(persistentBytes: keeps, transientBytes: 0)
        return persistent > keeps ? persistent - keeps : 0
    }
    return tenant
}

// MARK: - (a) Tenants are asked before any idle resident is evicted

@Test func realPressureAsksATenantBeforeEvictingAnIdleResident() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await engine.prepare(.llm, package: "a")                   // idle resident
    // Releases only 10 B of the 50 B overage: not enough, so the ladder must still run — and
    // the log shows the order.
    let tenant = await canvas(engine, log: log, keeps: 290)
    real.set(900)                                                  // 50 B over the 850 ceiling
    try await engine.prepare(.llm, package: "b")

    #expect(log.events == ["shrink:50", "unload:a"])               // asked FIRST, then evicted
    #expect(await engine.residentPackages["a"] == nil)
    #expect(await engine.residentPackages["b"] == 200)
    _ = tenant
}

// MARK: - (b) The declared drop covers the overage → no eviction, though the reading has not moved

@Test func aDeclaredDropCoveringTheOverageEvictsNothingDespiteTheLaggingReading() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await engine.prepare(.llm, package: "a")
    let tenant = await canvas(engine, log: log, keeps: 0)          // sheds all 300 B
    real.set(900)                                                  // and STAYS 900: Metal lag
    try await engine.prepare(.llm, package: "b")

    #expect(log.events == ["shrink:50"])                           // asked for the overage only
    #expect(log.unloads.isEmpty)                                   // 900 − 300 = 600 ≤ 850
    let residents = await engine.residentPackages
    #expect(residents["a"] == 200)
    #expect(residents["b"] == 200)
    #expect(tenant.footprint == .zero)
    #expect(real.read() == 900)                                    // the reading never dropped
}

// A tenant the declared-byte pass already asked is not asked again in the same admission, and
// its declared drop there is credited against the real reading too.
@Test func aTenantAskedByTheDeclaredPassIsCreditedNotAskedTwice() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await engine.prepare(.llm, package: "a")                   // 200
    // 200 + 700 tenant + 200 incoming = 1 100 declared → a 100 B deficit for pass (1); the
    // handler drops the whole 700 there.
    let tenant = await canvas(engine, log: log, keeps: 0, persistent: 700)
    real.set(900)
    try await engine.prepare(.llm, package: "b")

    #expect(log.events == ["shrink:100"])                          // once per admission
    #expect(await engine.residentPackages["a"] == 200)             // 900 − 700 credited
    _ = tenant
}

// The credit is per admission: the next one reads fresh, asks again, and — with nothing left
// to shed and the reading still high — evicts.
@Test func theCreditLastsOneAdmission() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await register(engine, "c", log: log)
    try await engine.prepare(.llm, package: "a")
    let tenant = await canvas(engine, log: log, keeps: 0)
    real.set(900)
    try await engine.prepare(.llm, package: "b")                   // credited: nothing evicted
    #expect(log.unloads.isEmpty)

    try await engine.prepare(.llm, package: "c")                   // asked again, sheds nothing
    #expect(log.shrinks == ["shrink:50", "shrink:50"])
    #expect(log.unloads == ["unload:a", "unload:b"])               // LRU, until none are idle
    #expect(Set(await engine.residentPackages.keys) == ["c"])
    _ = tenant
}

// MARK: - (c) A handler that releases nothing → the existing idle-LRU eviction, no hang, no loop

@Test func aHandlerThatReleasesNothingFallsThroughToIdleLRUEviction() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await register(engine, "c", log: log)
    try await engine.prepare(.llm, package: "a")
    try await engine.prepare(.llm, package: "b")
    let tenant = await canvas(engine, log: log, keeps: 300)        // releases nothing
    real.set(900)
    try await engine.prepare(.llm, package: "c")

    // Asked exactly once, even though the eviction loop iterated twice.
    #expect(log.events == ["shrink:50", "unload:a", "unload:b"])
    #expect(Set(await engine.residentPackages.keys) == ["c"])
    #expect(tenant.footprint.persistentBytes == 300)
}

@Test func anUnresponsiveHandlerUnderRealPressureIsBoundedThenTheLadderRuns() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real, shrinkTimeout: .milliseconds(50))
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await engine.prepare(.llm, package: "a")
    let tenant = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300) { _ in
        // Ignores cancellation on purpose: the engine must stop waiting at its deadline.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { done.resume() }
        }
        return 0
    }
    real.set(900)
    let start = ContinuousClock.now
    try await engine.prepare(.llm, package: "b")
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(log.unloads == ["unload:a"])
    _ = tenant
}

// MARK: - (d) No tenants → exactly the v0.58.0 pass

@Test func withoutTenantsRealPressureIsUnchanged() async throws {
    let log = EventLog()
    let real = RealMemory(0)
    let engine = engine(real)
    for name in ["a", "b", "c", "d"] { try await register(engine, name, log: log) }
    try await engine.prepare(.llm, package: "a")
    try await engine.prepare(.llm, package: "b")
    try await engine.prepare(.llm, package: "c")

    // One armed high reading: exactly one eviction (the LRU) — the pass takes no extra reading
    // when there is no tenant to ask.
    let before = real.reads
    real.armOnce(900)
    try await engine.prepare(.llm, package: "d")
    #expect(log.events == ["unload:a"])
    #expect(real.reads - before == 2)                              // high → evict → low → stop

    // A constant high reading: evicts every idle resident in LRU order, then stops — pressure
    // the engine cannot reclaim never loops.
    real.set(900)
    try await engine.prepare(.llm, package: "a")
    #expect(log.events == ["unload:a", "unload:b", "unload:c", "unload:d"])
    #expect(Set(await engine.residentPackages.keys) == ["a"])
}

// No host reading → the declared-byte pass only: the tenant is not asked (the declared accounting
// fits) and nothing is evicted.
@Test func withoutAHostReadingTenantsAreNotAskedByRealPressure() async throws {
    let log = EventLog()
    let real = RealMemory(nil)
    let engine = engine(real)
    try await register(engine, "a", log: log)
    try await register(engine, "b", log: log)
    try await engine.prepare(.llm, package: "a")
    let tenant = await canvas(engine, log: log, keeps: 0)
    try await engine.prepare(.llm, package: "b")
    #expect(log.events.isEmpty)
    #expect(Set(await engine.residentPackages.keys) == ["a", "b"])
    _ = tenant
}
