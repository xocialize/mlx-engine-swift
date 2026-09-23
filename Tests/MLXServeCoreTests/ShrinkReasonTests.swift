//
//  ShrinkReasonTests.swift
//  MLXServeCoreTests
//
//  Contract 1.46.0 — an external tenant is told WHY it is asked to shrink (AB-A-0097). A canvas
//  should drop its layer cache for an admission (it is what lets the model in) but not for a run
//  on a resident package under real pressure (it re-uploads the cache next frame; AB-R-0303 /
//  AB-R-0304 on a 24 GB M5 Pro). `ExternalShrinkRequest.reason` carries that; the bytes-only
//  handler form is wrapped and unchanged. Offline, mock packages, a mocked real reading, no MLX.
//
//  Budget 1 000 B, high-watermark 0.85 → R-MEM-1 ceiling 850 B. Packages are 200 B persistent +
//  0 transient unless noted.
//

import Foundation
import Testing
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mocks

private let budget: UInt64 = 1_000

/// The mocked `phys_footprint` (fixed: it lags a tenant's release, as Metal's does).
private final class RealMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64
    init(_ value: UInt64) { _value = value }
    func set(_ value: UInt64) { lock.withLock { _value = value } }
    func read() -> UInt64 { lock.withLock { _value } }
}

private func engine(_ real: RealMemory) -> MLXServeEngine {
    MLXServeEngine(governor: MemoryGovernor(budgetBytes: budget),
                   physFootprint: { real.read() })
}

private func mockManifest(name: String, persistent: UInt64, transient: UInt64) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/\(name)", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: persistent,
                                        peakActivationBytes: transient)],
            requiredBackends: [.metalGPU]),
        surfaces: [ToolDescriptor(name: name, capability: .llm, summary: "mock")])
}

/// 200 persistent + 0 transient.
@InferenceActor private final class SmallLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "small-llm", persistent: 200, transient: 0)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "small", finishReason: .stop)
    }
}

/// 600 persistent + 400 transient: exactly the whole budget.
@InferenceActor private final class WholeBudgetLLM: ModelPackage {
    typealias Configuration = StandardConfiguration
    nonisolated static var manifest: PackageManifest {
        mockManifest(name: "whole-llm", persistent: 600, transient: 400)
    }
    nonisolated init(configuration: StandardConfiguration) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "whole", finishReason: .stop)
    }
}

/// Every request a tenant received, in order.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(tenant: String, request: ExternalShrinkRequest)] = []
    func note(_ tenant: String, _ request: ExternalShrinkRequest) {
        lock.withLock { _requests.append((tenant, request)) }
    }
    var requests: [ExternalShrinkRequest] { lock.withLock { _requests.map(\.request) } }
    var tenants: [String] { lock.withLock { _requests.map(\.tenant) } }
}

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

private func register(_ engine: MLXServeEngine, _ name: String) async throws {
    try await engine.register(PackageRegistration.of(SmallLLM.self), configuration: cfg(),
                              id: PackageID(name))
}

/// A tenant with a request-form handler: logs the request, then declares `keeps` bytes.
private func tenant(_ engine: MLXServeEngine, _ id: String = "canvas", log: RequestLog,
                    persistent: UInt64, keeps: UInt64) async -> ExternalTenant {
    let tenant = await engine.registerExternalTenant(id: id, persistentBytes: persistent)
    tenant.setShrinkHandler { [weak tenant] (request: ExternalShrinkRequest) in
        log.note(id, request)
        tenant?.update(persistentBytes: keeps, transientBytes: 0)
        return persistent > keeps ? persistent - keeps : 0
    }
    return tenant
}

// MARK: - .admission

// The declared-byte pass of `prepare`: the tenant is told it is an admission, for which package.
@Test func prepareAsksWithAdmissionInTheDeclaredPass() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    let log = RequestLog()
    // 900 + 200 incoming = 1 100 declared → a 100 B deficit.
    let canvas = await tenant(engine, log: log, persistent: 900, keeps: 700)
    try await engine.prepare(.llm, package: "a")
    #expect(log.requests == [ExternalShrinkRequest(requestedBytes: 100, reason: .admission,
                                                   package: "a")])
    _ = canvas
}

// The R-MEM-1 pass of `prepare`: the declared sum fits, the real reading does not.
@Test func prepareAsksWithAdmissionInTheRealPressurePass() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    try await register(engine, "b")
    try await engine.prepare(.llm, package: "a")
    let log = RequestLog()
    let canvas = await tenant(engine, log: log, persistent: 300, keeps: 0)
    real.set(900)                                                  // 50 B over the ceiling
    try await engine.prepare(.llm, package: "b")
    #expect(log.requests == [ExternalShrinkRequest(requestedBytes: 50, reason: .admission,
                                                   package: "b")])
    _ = canvas
}

// A fresh load through `run` (not `prepare`) is an admission too, and both of its passes say so:
// the larger tenant covers the declared deficit, the smaller one is asked by R-MEM-1.
@Test func aFreshLoadsAdmissionSaysAdmissionInBothPasses() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    try await register(engine, "b")
    try await engine.prepare(.llm, package: "a")
    let log = RequestLog()
    // 200 + 700 + 50 + 200 incoming = 1 150 declared → a 150 B deficit, closed by the big one.
    let big = await tenant(engine, "big", log: log, persistent: 700, keeps: 550)
    let small = await tenant(engine, "small", log: log, persistent: 50, keeps: 0)
    real.set(1_100)                                                // 1 100 − 150 credited = 950
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "b")

    #expect(log.tenants == ["big", "small"])
    #expect(log.requests == [
        ExternalShrinkRequest(requestedBytes: 150, reason: .admission, package: "b"),  // declared
        ExternalShrinkRequest(requestedBytes: 100, reason: .admission, package: "b"),  // R-MEM-1
    ])
    _ = (big, small)
}

// A run on a resident package whose declared accounting no longer fits (a tenant grew since the
// admission, 1.43.0) is an admission: the alternative to the tenant's bytes is refusing the run.
@Test func aResidentRunOverTheDeclaredBudgetSaysAdmission() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await engine.register(PackageRegistration.of(WholeBudgetLLM.self), configuration: cfg(),
                              id: "whole")
    try await engine.prepare(.llm, package: "whole")               // 600 + 400 = the budget
    let log = RequestLog()
    let canvas = await tenant(engine, log: log, persistent: 200, keeps: 0)
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "whole")
    #expect(log.requests == [ExternalShrinkRequest(requestedBytes: 200, reason: .admission,
                                                   package: "whole")])
    _ = canvas
}

// MARK: - .runUnderRealPressure

// The 1.45.0 path: a resident run, the declared sum fits, the process is over the ceiling.
@Test func aResidentRunUnderRealPressureSaysSo() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    try await engine.prepare(.llm, package: "a")
    let log = RequestLog()
    let canvas = await tenant(engine, log: log, persistent: 300, keeps: 300)
    real.set(900)
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "a")
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "a")
    let expected = ExternalShrinkRequest(requestedBytes: 50, reason: .runUnderRealPressure,
                                         package: "a")
    #expect(log.requests == [expected, expected])                  // once per run, as in 1.45.0
    #expect(await engine.residentPackages["a"] == 200)             // and nothing evicted
    _ = canvas
}

// One engine, one tenant, the same session: admission first, then the steady-state runs.
@Test func theSameTenantSeesAdmissionThenRunUnderRealPressure() async throws {
    let real = RealMemory(900)
    let engine = engine(real)
    try await register(engine, "a")
    let log = RequestLog()
    let canvas = await tenant(engine, log: log, persistent: 300, keeps: 300)
    try await engine.prepare(.llm, package: "a")
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "a")
    #expect(log.requests.map(\.reason) == [.admission, .runUnderRealPressure])
    _ = canvas
}

// MARK: - Registration forms

// The request form through `registerExternalTenant(…onShrinkRequest:)`, trailing-closure style.
@Test func theRequestFormRegistersThroughTheOverload() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    try await engine.prepare(.llm, package: "a")
    let log = RequestLog()
    let canvas = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300) {
        request in
        log.note("canvas", request)
        switch request.reason {
        case .admission: return 300
        case .runUnderRealPressure: return 0
        }
    }
    real.set(900)
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "a")
    #expect(log.requests.map(\.reason) == [.runUnderRealPressure])
    _ = canvas
}

// The bytes-only form, both ways of installing it, sees exactly the bytes the request carries —
// on every path — and nothing else about it changed.
@Test func theLegacyFormStillReceivesTheBytesOnEveryPath() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    try await register(engine, "b")
    let requested = RequestLog()
    let viaRegister = await engine.registerExternalTenant(id: "canvas", persistentBytes: 900) {
        bytes in
        requested.note("legacy", ExternalShrinkRequest(requestedBytes: bytes, reason: .admission))
        return 0
    }
    // Declared pass: 900 + 200 = 1 100 → 100 B. The tenant keeps everything: refused, as before.
    await #expect(throws: EngineError.externalTenantsHoldMemory(required: 200, external: 900,
                                                                budget: budget)) {
        try await engine.prepare(.llm, package: "a")
    }
    viaRegister.withdraw()

    let viaSetter = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300)
    viaSetter.setShrinkHandler { bytes in
        requested.note("legacy", ExternalShrinkRequest(requestedBytes: bytes, reason: .admission))
        return 0
    }
    try await engine.prepare(.llm, package: "a")
    real.set(900)
    try await engine.prepare(.llm, package: "b")                   // R-MEM-1: 50 B
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "b") // resident run: 50 B
    #expect(requested.requests.map(\.requestedBytes) == [100, 50, 50])
}

// Installing one form replaces the other; `nil` clears either.
@Test func eitherFormReplacesTheOther() async throws {
    let real = RealMemory(0)
    let engine = engine(real)
    try await register(engine, "a")
    try await engine.prepare(.llm, package: "a")
    let log = RequestLog()
    let canvas = await engine.registerExternalTenant(id: "canvas", persistentBytes: 300) {
        (_: UInt64) in
        Issue.record("the replaced legacy handler was called")
        return 0
    }
    canvas.setShrinkHandler { (request: ExternalShrinkRequest) in
        log.note("canvas", request)
        return 0
    }
    real.set(900)
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "a")
    #expect(log.requests.count == 1)

    canvas.setShrinkHandler(nil)
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "a")
    #expect(log.requests.count == 1)                               // cleared: not asked
}

// No tenants: no request is built, nothing about admission or runs changes (the v0.60.0 path;
// the R-MEM-1 and declared suites pin that path in detail).
@Test func withoutTenantsNothingIsAskedAndNothingChanges() async throws {
    let real = RealMemory(900)
    let engine = engine(real)
    try await register(engine, "a")
    try await register(engine, "b")
    try await engine.prepare(.llm, package: "a")
    try await engine.prepare(.llm, package: "b")                   // evicts a (real pressure)
    _ = try await engine.run(LLMRequest(prompt: "x"), package: "b")
    #expect(await engine.residentPackages == ["b": 200])
    #expect(await engine.memory.externalTenants.isEmpty)
}
