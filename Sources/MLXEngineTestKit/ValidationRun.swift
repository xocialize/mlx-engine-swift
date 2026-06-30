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
    public var residentFloorBytes: UInt64 = 0      // phys right after run returns ≈ weights resident
    public var coResidentBackers: [String] = []    // resident packages backing this capability
    public var inputSummary: String?

    public init() {}

    /// Measured transient = peak − floor (the activation high-water on top of resident weights).
    public var activationBytes: UInt64 { peakFootprint > residentFloorBytes ? peakFootprint - residentFloorBytes : 0 }

    /// Machine-readable line for headless capture (mirrors the per-package MEM/SPLIT convention).
    public func splitLogLine(_ label: String) -> String {
        String(format: "[%@] SPLIT floor=%.2fGB peak=%.2fGB act=%.2fGB engine=%.2fGB reserve=%.2fGB load=%.1fs run=%.1fs",
               label,
               gb(residentFloorBytes), gb(peakFootprint), gb(activationBytes),
               gb(engineResidentBytes), gb(transientReserveBytes), loadSeconds, runSeconds)
    }
    private func gb(_ b: UInt64) -> Double { Double(b) / 1_000_000_000 }
}

/// The reusable register → prepare(timed) → run(timed) → capture harness — generalized from the proving
/// ground's `runFlow` (sampler + heartbeat + security-scoped grants), MLX-free. Each category testing app
/// drives every package through this instead of hand-rolling the flow, so the split/reserve/peak readout
/// is uniform. The precise resident floor stays the package's MEM-line job; here `residentFloorBytes` is
/// the post-run `phys_footprint` (≈ floor when the package clears its transient cache in run/decode).
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

        if !coResident { await engine.evict(capability) }
        let packageID = try await engine.register(registration, configuration: configuration)

        let loadStart = Date()
        try await engine.prepare(capability, package: packageID)
        m.loadSeconds = Date().timeIntervalSince(loadStart)

        let runStart = Date()
        let response = try await engine.run(request, package: packageID)
        m.runSeconds = Date().timeIntervalSince(runStart)

        m.residentFloorBytes = HostMemory.physFootprint() ?? 0   // post-run ≈ resident floor (cache cleared)
        m.peakFootprint = max(m.peakFootprint, sampler.peak, m.residentFloorBytes)

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
