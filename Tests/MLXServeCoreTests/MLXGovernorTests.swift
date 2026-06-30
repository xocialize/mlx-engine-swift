import Testing
import Foundation
import MLXToolKit
@testable import MLXServeCore

// MARK: - Mock packages with tailored requirements (no MLX)

private func mockManifest(capability: Capability, footprint: UInt64,
                          backends: Set<Backend>, chipFloor: ChipTier?) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/mock", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: footprint)],
            requiredBackends: backends,
            os: OSRequirement(),
            chipFloor: chipFloor
        ),
        surfaces: [ToolDescriptor(name: "mock-\(capability.rawValue)", capability: capability, summary: "mock")]
    )
}

private protocol MockBase: ModelPackage where Configuration == StandardConfiguration {}
extension MockBase {
    public func load() async throws {}
    public func unload() async {}
    public func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

@InferenceActor private final class MockLLM: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .llm, footprint: 60, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockTTS: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .tts, footprint: 60, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockImage60: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .textToImage, footprint: 60, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockBig: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .textToImage, footprint: 10_000, backends: [.metalGPU], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockANE: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .imageAnalysis, footprint: 10, backends: [.coreMLANE], chipFloor: nil) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockUltra: MockBase {
    nonisolated static var manifest: PackageManifest { mockManifest(capability: .videoAnalysis, footprint: 10, backends: [.metalGPU], chipFloor: .ultra) }
    nonisolated init(configuration: StandardConfiguration) {}
}

private func cfg() -> StandardConfiguration { StandardConfiguration(weightsRepo: "mock/mock") }

// These tests use symbolic *byte* budgets (90, 300, …), so the live `phys_footprint` (gigabytes) would
// always trip the R-MEM-1 real-pressure trigger. Default the injected reading to `nil` (trigger off);
// the dedicated real-pressure tests below pass an explicit provider.
private func engine(budget: UInt64, backends: Set<Backend> = [.metalGPU], chip: ChipTier = .max,
                    physFootprint: @escaping @Sendable () -> UInt64? = { nil }) -> MLXServeEngine {
    let device = DeviceProfile(chipTier: chip,
                               macOS: SemanticVersion(major: 26, minor: 0, patch: 0),
                               backends: backends,
                               totalMemoryBytes: 64_000_000_000)
    return MLXServeEngine(device: device, governor: MemoryGovernor(budgetBytes: budget),
                          physFootprint: physFootprint)
}

// MARK: - Eligibility (C10)

@Test func registerRejectsMissingBackend() async {
    let e = engine(budget: 1_000, backends: [.metalGPU])
    await #expect(throws: EngineError.ineligible(.missingBackend(.coreMLANE))) {
        try await e.register(PackageRegistration.of(MockANE.self), configuration: cfg())
    }
}

@Test func registerRejectsChipBelowFloor() async {
    let e = engine(budget: 1_000, chip: .base)
    await #expect(throws: EngineError.ineligible(.chipBelowFloor(required: .ultra, have: .base))) {
        try await e.register(PackageRegistration.of(MockUltra.self), configuration: cfg())
    }
}

// MARK: - Memory governance

@Test func prepareRejectsFootprintLargerThanBudget() async throws {
    let e = engine(budget: 100)
    try await e.register(PackageRegistration.of(MockBig.self), configuration: cfg())
    await #expect(throws: EngineError.self) {
        _ = try await e.prepare(.textToImage)
    }
}

@Test func evictsLRUWhenFull() async throws {
    let e = engine(budget: 100) // fits one 60-byte working set
    try await e.register(PackageRegistration.of(MockLLM.self), configuration: cfg())
    try await e.register(PackageRegistration.of(MockTTS.self), configuration: cfg())

    try await e.prepare(.llm)
    var snap = await e.memory
    #expect(snap.residentBytes == 60)
    #expect(snap.residents[.llm] == 60)

    try await e.prepare(.tts) // needs 60, only 40 free → evict .llm
    snap = await e.memory
    #expect(snap.residentBytes == 60)
    #expect(snap.residents[.tts] == 60)
    #expect(snap.residents[.llm] == nil)
}

@Test func lruKeepsRecentlyUsed() async throws {
    let e = engine(budget: 120) // fits two 60-byte working sets
    try await e.register(PackageRegistration.of(MockLLM.self), configuration: cfg())
    try await e.register(PackageRegistration.of(MockTTS.self), configuration: cfg())
    try await e.register(PackageRegistration.of(MockImage60.self), configuration: cfg())

    try await e.prepare(.llm)
    try await e.prepare(.tts)                       // resident: llm + tts (120)
    _ = try await e.run(LLMRequest(prompt: "hi"))   // touch .llm → most recently used

    try await e.prepare(.textToImage)               // needs 60 → evict LRU (.tts)
    let snap = await e.memory
    #expect(snap.residents[.tts] == nil)
    #expect(snap.residents[.llm] == 60)
    #expect(snap.residents[.textToImage] == 60)
}

// MARK: - Multi-package per capability (modularity)

@InferenceActor private final class MockImageAlt: MockBase {
    nonisolated static var manifest: PackageManifest {
        var m = mockManifest(capability: .textToImage, footprint: 30, backends: [.metalGPU], chipFloor: nil)
        return PackageManifest(
            license: m.license, provenance: m.provenance, requirements: m.requirements,
            specialties: m.specialties,
            surfaces: [ToolDescriptor(name: "mock-t2i-alt", capability: .textToImage, summary: "alt")])
    }
    nonisolated init(configuration: StandardConfiguration) {}
}

@Test func multiPackageSelectionAndDefaults() async throws {
    let e = engine(budget: 200)
    let primary = try await e.register(PackageRegistration.of(MockImage60.self), configuration: cfg())
    let alt = try await e.register(PackageRegistration.of(MockImageAlt.self), configuration: cfg())

    // Both back the capability; LAST registration is the default (swap-flow compatible).
    #expect(await e.packages(for: .textToImage).count == 2)
    #expect(await e.defaultPackage(for: .textToImage) == alt)

    // Re-point routing without re-registering.
    try await e.setDefault(primary, for: .textToImage)
    #expect(await e.defaultPackage(for: .textToImage) == primary)

    // Per-request selection: both can be resident simultaneously (60 + 30 ≤ 200).
    try await e.prepare(.textToImage)                 // default → primary (60)
    try await e.prepare(.textToImage, package: alt)   // explicit → alt (30)
    let residentBytes = await e.memory.residentBytes
    #expect(residentBytes == 90)

    // Selecting an id that doesn't back the capability is an error.
    await #expect(throws: EngineError.unknownPackage(.llm, alt)) {
        try await e.prepare(.llm, package: alt)
    }

    // Evict the specific module; the default stays resident.
    await e.evict(.textToImage, package: alt)
    let after = await e.residentPackages
    #expect(after[alt] == nil)
    #expect(after[primary] == 60)
}

// MARK: - Config-aware footprint (ISSUES W1)

/// Multi-footprint manifest (bf16 160 / int4 56) — the shape that triggered W1.
private func mockMultiManifest() -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/multi", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .bf16, residentBytes: 160),
                         QuantFootprint(quant: .int4, residentBytes: 56)],
            requiredBackends: [.metalGPU],
            os: OSRequirement(),
            chipFloor: nil),
        surfaces: [ToolDescriptor(name: "mock-multi", capability: .textToImage, summary: "mock")])
}

@InferenceActor private final class MockMulti: MockBase {
    nonisolated static var manifest: PackageManifest { mockMultiManifest() }
    nonisolated init(configuration: StandardConfiguration) {}
}

@Test func footprintMatchesRegisteredVariant() {
    let gov = MemoryGovernor(budgetBytes: 90)  // bf16 (160) exceeds budget → exposes the W1 trap
    let reqs = mockMultiManifest().requirements
    // Variant-agnostic survey: largest-that-fits picks int4 56 (bf16 doesn't fit) — the old charge.
    #expect(gov.footprint(for: reqs) == 56)
    // Config-aware: each registered variant is charged its own declared footprint.
    #expect(gov.footprint(for: reqs, quant: .bf16) == 160)  // NOT the silent 56 under-reserve
    #expect(gov.footprint(for: reqs, quant: .int4) == 56)
    // Safe fallbacks: no opt-in (nil) / no matching declared footprint → largest-that-fits.
    #expect(gov.footprint(for: reqs, quant: nil) == 56)
    #expect(gov.footprint(for: reqs, quant: .fp32) == 56)
}

@Test func registerChargesConfigVariant() async throws {
    // StandardConfiguration conforms to QuantConfigured → the engine charges the registered variant's
    // footprint end-to-end (register → prepare → resident). Budget fits bf16.
    let eBf16 = engine(budget: 300)
    try await eBf16.register(PackageRegistration.of(MockMulti.self),
                             configuration: StandardConfiguration(weightsRepo: "mock/multi", quant: .bf16))
    try await eBf16.prepare(.textToImage)
    #expect(await eBf16.memory.residentBytes == 160)

    let eInt4 = engine(budget: 300)
    try await eInt4.register(PackageRegistration.of(MockMulti.self),
                             configuration: StandardConfiguration(weightsRepo: "mock/multi", quant: .int4))
    try await eInt4.prepare(.textToImage)
    #expect(await eInt4.memory.residentBytes == 56)
}

@Test func bf16NoLongerSilentlyUnderReserves() async throws {
    // The W1 safety win: at a budget where bf16 (160) doesn't fit, a bf16 registration is charged
    // 160 and REJECTED at prepare — not silently admitted at the int4 56 figure (the old bug).
    let e = engine(budget: 90)
    try await e.register(PackageRegistration.of(MockMulti.self),
                         configuration: StandardConfiguration(weightsRepo: "mock/multi", quant: .bf16))
    await #expect(throws: EngineError.self) {
        _ = try await e.prepare(.textToImage)
    }
}

// MARK: - Config-aware footprint HINT — same-quant multi-mode (3.1, the BiRefNet case)

/// Single declared fp16 footprint (the "fast" envelope) — the shape where two modes share a quant but
/// have very different working sets, so `QuantFootprint` (keyed on quant) can't tell them apart.
private func mockMattingManifest() -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/matting", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .fp16, residentBytes: 65)],  // fast envelope
            requiredBackends: [.metalGPU],
            os: OSRequirement(),
            chipFloor: nil),
        surfaces: [ToolDescriptor(name: "mock-matting", capability: .matting, summary: "mock")])
}

/// A mode-tiered config at one quant (fp16) that declares the selected mode's footprint via a hint.
private struct ModeConfig: PackageConfiguration, QuantConfigured, FootprintConfigured {
    var quant: Quant = .fp16
    var residentBytesHint: UInt64?
}

@InferenceActor private final class MockMatting: ModelPackage {
    typealias Configuration = ModeConfig
    nonisolated static var manifest: PackageManifest { mockMattingManifest() }
    nonisolated init(configuration: ModeConfig) {}
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

@Test func footprintHintOverridesQuantAndSurvey() {
    let gov = MemoryGovernor(budgetBytes: 300)
    let reqs = mockMattingManifest().requirements
    // No hint → quant match (fp16 65), or largest-that-fits when the quant isn't declared.
    #expect(gov.footprint(for: reqs, quant: .fp16, hint: nil) == 65)
    #expect(gov.footprint(for: reqs, quant: .int4, hint: nil) == 65)   // no int4 declared → survey
    // Hint wins over both — the "best" mode declares its own (larger) working set at the same quant.
    #expect(gov.footprint(for: reqs, quant: .fp16, hint: 183) == 183)
    #expect(gov.footprint(for: reqs, quant: nil, hint: 183) == 183)
}

@Test func registerChargesFootprintHintPerMode() async throws {
    // The BiRefNet fix end-to-end: one package, two same-quant modes, charged their real footprints.
    let eFast = engine(budget: 300)
    try await eFast.register(PackageRegistration.of(MockMatting.self),
                             configuration: ModeConfig(residentBytesHint: nil))  // fast → fp16 65
    try await eFast.prepare(.matting)
    #expect(await eFast.memory.residentBytes == 65)

    let eBest = engine(budget: 300)
    try await eBest.register(PackageRegistration.of(MockMatting.self),
                             configuration: ModeConfig(residentBytesHint: 183))  // best → 183
    try await eBest.prepare(.matting)
    #expect(await eBest.memory.residentBytes == 183)
}

@Test func admissibilityIsConfigAware() async {
    // The affordable tier stays admissible where the survey-charged best tier wouldn't: at budget 100,
    // the fast mode (65) fits; the best mode (183) doesn't — and the config-aware overload reports each.
    let e = engine(budget: 100)
    let reqs = mockMattingManifest().requirements
    let fast = await e.admissibility(for: reqs, configuration: ModeConfig(residentBytesHint: nil))
    let best = await e.admissibility(for: reqs, configuration: ModeConfig(residentBytesHint: 183))
    #expect(fast.footprint == 65)
    #expect(fast.fitsBudget)
    #expect(best.footprint == 183)
    #expect(!best.fitsBudget)
    // The variant-agnostic survey overload still works (largest-that-fits = fp16 65).
    let survey = await e.admissibility(for: reqs)
    #expect(survey.footprint == 65)
}

// MARK: - R-MEM-1 real-pressure trigger (3.7)

/// A controllable `phys_footprint`. Reads `low` until `arm()`, then returns `high` for exactly the next
/// read and disarms — so a test drives exactly one real-pressure eviction at a chosen moment, robust to
/// how many benign reads happened before (every cold prepare reads `phys_footprint` once).
private final class ArmedMem: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let high: UInt64, low: UInt64
    init(high: UInt64, low: UInt64 = 0) { self.high = high; self.low = low }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func read() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        if armed { armed = false; return high }
        return low
    }
}

@Test func realPressureEvictsIdleEvenWhenDeclaredBytesFit() async throws {
    // Declared bytes fit easily (60 + 60 ≤ 300), but the *actual* footprint sits over the 0.85
    // watermark (ceiling 255). Admitting the second model must reclaim the idle first one on real
    // pressure — the gap declared-byte arithmetic alone would miss (R-MEM-1).
    let e = engine(budget: 300, physFootprint: { 260 })  // constant > ceiling 255
    let llm = try await e.register(PackageRegistration.of(MockLLM.self), configuration: cfg())
    try await e.prepare(.llm)
    try await e.register(PackageRegistration.of(MockTTS.self), configuration: cfg())
    try await e.prepare(.tts)  // admission here trips real pressure → evicts the idle LLM

    let resident = await e.residentPackages
    #expect(resident[llm] == nil)              // reclaimed on real pressure
    #expect(await e.memory.residentBytes == 60) // only TTS remains
    #expect(await e.memory.underRealPressure)
}

@Test func realPressureKeepsRecentlyUsed() async throws {
    // The pressure-aware companion to `lruKeepsRecentlyUsed`: under real pressure the LRU idle resident
    // is evicted in LRU order, and a more-recently-used one survives. Budget is large so declared bytes
    // never force eviction (3×60 ≤ 1000); ArmedMem fires a single high reading during the third
    // admission, so exactly one resident — the LRU — is reclaimed.
    let mem = ArmedMem(high: 900)  // > ceiling (0.85 × 1000 = 850)
    let e = engine(budget: 1_000, physFootprint: { mem.read() })
    let llm = try await e.register(PackageRegistration.of(MockLLM.self), configuration: cfg())
    try await e.prepare(.llm)                     // llm loaded first
    let tts = try await e.register(PackageRegistration.of(MockTTS.self), configuration: cfg())
    try await e.prepare(.tts)                     // tts loaded after
    _ = try await e.run(LLMRequest(prompt: "x"))  // touch llm → tts is now the LRU
    try await e.register(PackageRegistration.of(MockImage60.self), configuration: cfg())
    mem.arm()                                     // arm real pressure for the next admission
    try await e.prepare(.textToImage)             // one real-pressure eviction → the LRU (tts)

    let resident = await e.residentPackages
    #expect(resident[tts] == nil)   // LRU idle evicted under real pressure
    #expect(resident[llm] != nil)   // recently-used survives
    #expect(resident.count == 2)    // exactly one eviction (llm + image remain)
}

// MARK: - Serialized-inference transient reserve (E1)

/// One quant with a split footprint: 40 persistent weights + 30 transient activation peak.
private func mockSplitManifest(capability: Capability) -> PackageManifest {
    PackageManifest(
        license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
        provenance: Provenance(sourceRepo: "mock/split-\(capability.rawValue)", revision: "main", tier: 1),
        requirements: RequirementsManifest(
            footprints: [QuantFootprint(quant: .int4, residentBytes: 40, peakActivationBytes: 30)],
            requiredBackends: [.metalGPU], os: OSRequirement(), chipFloor: nil),
        surfaces: [ToolDescriptor(name: "mock-split-\(capability.rawValue)", capability: capability, summary: "mock")])
}

@InferenceActor private final class MockSplitLLM: MockBase {
    nonisolated static var manifest: PackageManifest { mockSplitManifest(capability: .llm) }
    nonisolated init(configuration: StandardConfiguration) {}
}
@InferenceActor private final class MockSplitTTS: MockBase {
    nonisolated static var manifest: PackageManifest { mockSplitManifest(capability: .tts) }
    nonisolated init(configuration: StandardConfiguration) {}
}

@Test func footprintSplitResolves() {
    let gov = MemoryGovernor(budgetBytes: 1000)
    let reqs = mockSplitManifest(capability: .llm).requirements
    let s = gov.footprintSplit(for: reqs, quant: .int4, persistentHint: nil, transientHint: nil)
    #expect(s.persistent == 40)
    #expect(s.transient == 30)
    // Hints override either half independently (the per-mode case).
    let h = gov.footprintSplit(for: reqs, quant: .int4, persistentHint: 100, transientHint: 200)
    #expect(h.persistent == 100)
    #expect(h.transient == 200)
}

@Test func transientReserveIsSingleNotSummed() async throws {
    // Two models, each 40 weights + 30 activation. Serialized inference means ONE transient is live at
    // a time, so co-residency needs 40+40 + max(30,30) = 110, NOT 40+40 + 30+30 = 140. At budget 120 both
    // fit; the naive weights+activation model (70 each) would have evicted one.
    let e = engine(budget: 120)
    let llm = try await e.register(PackageRegistration.of(MockSplitLLM.self), configuration: cfg())
    let tts = try await e.register(PackageRegistration.of(MockSplitTTS.self), configuration: cfg())
    try await e.prepare(.llm)
    try await e.prepare(.tts)

    let resident = await e.residentPackages
    #expect(resident[llm] == 40)            // persistent only is charged as residency
    #expect(resident[tts] == 40)
    #expect(resident.count == 2)            // both co-resident — the win
    let mem = await e.memory
    #expect(mem.residentBytes == 80)        // Σ persistent
    #expect(mem.transientReserveBytes == 30) // ONE reserve, not 60
    #expect(mem.availableBytes == 10)        // 120 − 80 − 30
}

@Test func transientReserveEvictsWhenAccountingExceedsBudget() async throws {
    // Same two models at budget 100: 40+40 + max(30) = 110 > 100, so admitting the second evicts the first.
    let e = engine(budget: 100)
    let llm = try await e.register(PackageRegistration.of(MockSplitLLM.self), configuration: cfg())
    try await e.prepare(.llm)
    try await e.register(PackageRegistration.of(MockSplitTTS.self), configuration: cfg())
    try await e.prepare(.tts)
    let resident = await e.residentPackages
    #expect(resident[llm] == nil)           // evicted to fit the second's accounting
    #expect(resident.count == 1)
}

@Test func admissibilityCountsTransient() async {
    // A model's own peak is persistent + transient (70). It fits a 80 budget but not a 60 one.
    let reqs = mockSplitManifest(capability: .llm).requirements
    let big = engine(budget: 80)
    let small = engine(budget: 60)
    let a = await big.admissibility(for: reqs, quant: .int4)
    let b = await small.admissibility(for: reqs, quant: .int4)
    #expect(a.footprint == 70)
    #expect(a.fitsBudget)
    #expect(b.footprint == 70)
    #expect(!b.fitsBudget)                   // 70 > 60 — transient counted
}

// MARK: - BudgetAware load-time stamp (E2)

/// Records the headroom the engine stamped at load time.
private final class BudgetSpy: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64?
    func set(_ v: UInt64?) { lock.lock(); value = v; lock.unlock() }
    var seen: UInt64? { lock.lock(); defer { lock.unlock() }; return value }
}
nonisolated(unsafe) private var budgetSpy = BudgetSpy()

private struct BudgetCfg: PackageConfiguration, BudgetAware {
    var availableBudgetBytes: UInt64?
}

@InferenceActor private final class MockBudgetAware: ModelPackage {
    typealias Configuration = BudgetCfg
    nonisolated static var manifest: PackageManifest { mockSplitManifest(capability: .imageRestore) }
    nonisolated init(configuration: BudgetCfg) { budgetSpy.set(configuration.availableBudgetBytes) }
    func load() async throws {}
    func unload() async {}
    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        LLMResponse(text: "ok", finishReason: .stop)
    }
}

@Test func budgetAwareReceivesHeadroomAtLoad() async throws {
    // Pre-load a 40-weight/30-transient resident, then load a BudgetAware model. It should see
    // budget − residency(other) − reserve(other) = 1000 − 40 − 30 = 930.
    budgetSpy.set(nil)
    let e = engine(budget: 1000)
    try await e.register(PackageRegistration.of(MockSplitLLM.self), configuration: cfg())
    try await e.prepare(.llm)
    try await e.register(PackageRegistration.of(MockBudgetAware.self), configuration: BudgetCfg())
    try await e.prepare(.imageRestore)
    #expect(budgetSpy.seen == 930)
}
