import Foundation
import MLXToolKit
import MLXServeCore

/// Timing + memory captured around one engine-driven run — the generalized `RunMetrics` from the
/// retired proving-ground app, extended for the 1.14 split (resident floor vs activation +
/// transient reserve). Bind a readout to this; emit `splitLogLine` for headless capture.
public struct ValidationRun: Sendable {
    public var loadSeconds: Double = 0
    public var runSeconds: Double = 0
    public var engineResidentBytes: UInt64 = 0     // governor charge for this capability
    public var transientReserveBytes: UInt64 = 0   // the one shared activation reserve (1.14)
    public var baselineFootprint: UInt64 = 0       // phys before load
    public var peakFootprint: UInt64 = 0           // max phys across load+run
    public var residentFloorBytes: UInt64 = 0      // phys right after LOAD (pre-run) ≈ true weights resident
    public var postRunResidentBytes: UInt64 = 0    // phys after run+clearCache; > floor ⇒ live model retains intermediates
    public var coResidentBackers: [String] = []    // resident packages backing this capability
    public var inputSummary: String?

    public init() {}

    /// Measured transient = peak − floor (the activation high-water on top of resident weights). Floor is
    /// the **post-load** resident, so this is the honest activation even when a package retains post-run
    /// intermediates (which would otherwise inflate a post-run floor and collapse this toward 0).
    public var activationBytes: UInt64 { peakFootprint > residentFloorBytes ? peakFootprint - residentFloorBytes : 0 }

    /// Bytes the live model holds AFTER its run + clearCache, beyond the post-load weights floor. A large
    /// value is a **retention leak**: the model graph keeps run intermediates referenced (so clearCache —
    /// which only frees *unreferenced* pool buffers — can't reclaim them), and the resident cost balloons
    /// across successive requests until the package is evicted. ~0 is clean (NAFNet/DDColor flagged this).
    public var retainedAfterRunBytes: UInt64 { postRunResidentBytes > residentFloorBytes ? postRunResidentBytes - residentFloorBytes : 0 }

    /// Machine-readable line for headless capture (mirrors the per-package MEM/SPLIT convention). `floor` is
    /// post-load (true resident); `retain` flags post-run retention (≈0 = clean).
    public func splitLogLine(_ label: String) -> String {
        String(format: "[%@] SPLIT floor=%.2fGB peak=%.2fGB act=%.2fGB retain=%.2fGB engine=%.2fGB reserve=%.2fGB load=%.1fs run=%.1fs",
               label,
               gb(residentFloorBytes), gb(peakFootprint), gb(activationBytes), gb(retainedAfterRunBytes),
               gb(engineResidentBytes), gb(transientReserveBytes), loadSeconds, runSeconds)
    }
    private func gb(_ b: UInt64) -> Double { Double(b) / 1_000_000_000 }
}

/// The reusable register → prepare(timed) → run(timed) → capture harness — generalized from the proving
/// ground's `runFlow` (sampler + heartbeat + security-scoped grants), MLX-free. Each category testing app
/// drives every package through this instead of hand-rolling the flow, so the split/reserve/peak readout
/// is uniform. `residentFloorBytes` is the **post-load** `phys_footprint` (true weights resident, before the
/// run allocates activation); `postRunResidentBytes` is read again after the run so `retainedAfterRunBytes`
/// surfaces any post-run retention separately instead of inflating the floor. Pass `clearCache`
/// (`{ MLX.GPU.clearCache() }`, the kit is MLX-free) so both reads drop unreferenced pool buffers first.
/// Use `isolate: true` for a clean per-model measure that evicts all prior residents.
@MainActor
public enum ValidationHarness {
    public struct Result { public let response: any CapabilityResponse; public let run: ValidationRun }

    public static func run(
        engine: MLXServeEngine,
        registration: PackageRegistration,
        configuration: any PackageConfiguration,
        capability: Capability,
        request: any CapabilityRequest,
        coResident: Bool = false,                 // additive register (multi-package) vs evict-then-register
        isolate: Bool = false,                    // evict ALL prior residents first (clean per-model measure)
        clearCache: (@Sendable () -> Void)? = nil, // app passes `{ MLX.GPU.clearCache() }` — see note below
        grantedRoots: [URL] = [],                 // security-scoped roots held for the whole load+run
        inputSummary: String? = nil,
        heartbeatLabel: String? = nil             // non-nil → periodic "alive" console line for long runs
    ) async throws -> Result {
        var m = ValidationRun()
        m.inputSummary = inputSummary
        m.baselineFootprint = HostMemory.physFootprint() ?? 0
        m.peakFootprint = m.baselineFootprint

        let sampler = MemorySampler()
        sampler.start(initial: m.baselineFootprint)
        defer { sampler.stop() }

        let started = Date()
        let heartbeat: Task<Void, Never>? = heartbeatLabel.map { label in
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { break }
                    print(String(format: "[%@] alive %.0fs · peak %.2f GB", label,
                                 Date().timeIntervalSince(started), Double(sampler.peak) / 1_000_000_000))
                }
            }
        }
        defer { heartbeat?.cancel() }

        var startedScopes: [URL] = []
        for url in grantedRoots where url.startAccessingSecurityScopedResource() { startedScopes.append(url) }
        defer { for url in startedScopes { url.stopAccessingSecurityScopedResource() } }

        // Isolation: evict EVERY prior resident (not just this capability) so a multi-package validation
        // session measures each model alone and process RSS doesn't accumulate across runs. Without this
        // the harness evicts only `capability`, leaving prior different-capability residents in memory —
        // the monotonic-RSS-growth the image app's acceptance run found. `clearCache` after eviction
        // releases the freed buffers back (MLX holds them in its pool otherwise; the engine is MLX-free).
        if isolate {
            for id in await engine.residentPackages.keys { await engine.evict(package: id) }
            clearCache?()
        } else if !coResident {
            await engine.evict(capability)
        }
        let packageID = try await engine.register(registration, configuration: configuration)

        let loadStart = Date()
        try await engine.prepare(capability, package: packageID)
        m.loadSeconds = Date().timeIntervalSince(loadStart)

        // Resident floor = phys right after LOAD, before the run allocates any activation. Reading it here
        // (not post-run) is the fix for packages whose live model retains run intermediates: a post-run
        // floor conflates resident weights with those retained buffers (which `clearCache` can't free —
        // they're still referenced), over-reads the floor, and collapses `activationBytes` to ~0 (the
        // NAFNet/DDColor 5.4 GB "floor-not-dropping" finding). clearCache first to drop load-time scratch.
        clearCache?()
        m.residentFloorBytes = HostMemory.physFootprint() ?? 0

        let runStart = Date()
        let response = try await engine.run(request, package: packageID)
        m.runSeconds = Date().timeIntervalSince(runStart)

        // Peak is the sampler's high-water DURING the run (post-load weights + activation). Post-run, read
        // the resident AGAIN after clearCache: if it sits well above the post-load floor, the live model is
        // retaining run intermediates (a retention leak surfaced as `retainedAfterRunBytes`) — distinct from
        // the activation peak, and the real signal behind a stubborn floor.
        m.peakFootprint = max(m.peakFootprint, sampler.peak, HostMemory.physFootprint() ?? 0)
        clearCache?()
        m.postRunResidentBytes = HostMemory.physFootprint() ?? 0

        let snapshot = await engine.memory
        m.engineResidentBytes = snapshot.residents[capability] ?? 0
        m.transientReserveBytes = snapshot.transientReserveBytes
        let backers = await engine.packages(for: capability)
        let resident = await engine.residentPackages
        m.coResidentBackers = backers.compactMap { id in resident[id].map { "\(id.description) \(fmt($0))" } }.sorted()

        return Result(response: response, run: m)
    }

    private static func fmt(_ b: UInt64) -> String { String(format: "%.2fGB", Double(b) / 1_000_000_000) }
}
