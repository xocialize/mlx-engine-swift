import Foundation
import SwiftUI
import MLXToolKit
import MLXServeCore

/// "Does this variant fit a 16/32/64/128 GB Mac?" — the tier seam category apps lack. On a big-RAM dev
/// box nothing is inadmissible, so this is the only way to catch tier regressions. Pure (no live engine):
/// it spins a throwaway `MemoryGovernor` per simulated budget and reuses `footprintSplit`, so the numbers
/// match exactly what a real registration of that variant would be charged. The marquee BiRefNet case
/// (fast vs best, both fp16) is the one to drive this with.
public enum AdmissibilityTiers {
    /// Common unified-memory tiers (total RAM, before the budget fraction).
    public static let standard: [UInt64] = [16, 32, 64, 128].map { UInt64($0) * 1_000_000_000 }

    public struct TierVerdict: Sendable, Identifiable {
        public let totalBytes: UInt64      // device unified memory
        public let budgetBytes: UInt64     // after the fraction
        public let ownPeakBytes: UInt64    // persistent + transient (the variant's own peak)
        public let fits: Bool
        public var id: UInt64 { totalBytes }
    }

    /// Evaluate a variant (by quant + optional `FootprintConfigured` hints) across device tiers.
    public static func check(requirements: RequirementsManifest,
                             quant: Quant? = nil,
                             persistentHint: UInt64? = nil,
                             transientHint: UInt64? = nil,
                             fraction: Double = 0.7,
                             tiers: [UInt64] = standard) -> [TierVerdict] {
        tiers.map { total in
            let gov = MemoryGovernor(budgetBytes: UInt64(Double(total) * fraction))
            let s = gov.footprintSplit(for: requirements, quant: quant,
                                       persistentHint: persistentHint, transientHint: transientHint)
            let own = s.persistent &+ s.transient
            return TierVerdict(totalBytes: total, budgetBytes: gov.budgetBytes, ownPeakBytes: own,
                               fits: own <= gov.budgetBytes)
        }
    }
}

/// Plain readout of the tier check — drop into any category testing app.
public struct AdmissibilityTierView: View {
    private let title: String
    private let verdicts: [AdmissibilityTiers.TierVerdict]
    public init(title: String, verdicts: [AdmissibilityTiers.TierVerdict]) {
        self.title = title; self.verdicts = verdicts
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).bold()
            ForEach(verdicts) { v in
                HStack {
                    Text("\(v.totalBytes / 1_000_000_000) GB Mac").font(.caption.monospaced())
                    Spacer()
                    Text(String(format: "needs %.1f GB", Double(v.ownPeakBytes) / 1_000_000_000))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(v.fits ? "✅" : "❌")
                }
            }
        }
    }
}
