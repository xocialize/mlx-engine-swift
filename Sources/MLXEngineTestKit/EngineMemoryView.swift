import SwiftUI
import MLXServeCore

/// The memory readout every category testing app should show — the seams that were PARTIAL/MISSING
/// across the LTX video app + the image app: the `MemorySnapshot` accounting (budget · resident ·
/// **transient reserve** · available · real `phys_footprint` + pressure) and, when a run has been
/// measured, the **split** (resident floor vs activation peak). Plain SwiftUI (no design-token
/// dependency) so any app drops it in and restyles as needed.
public struct EngineMemoryView: View {
    private let snapshot: MemorySnapshot
    private let run: ValidationRun?

    public init(snapshot: MemorySnapshot, run: ValidationRun? = nil) {
        self.snapshot = snapshot
        self.run = run
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Engine memory").font(.caption).bold()
            row("Budget", snapshot.budgetBytes)
            row("Resident (weights)", snapshot.residentBytes)
            row("Transient reserve", snapshot.transientReserveBytes)   // the headline 1.14 signal
            row("Available", snapshot.availableBytes)
            if let real = snapshot.realResidentBytes {
                HStack {
                    Text("Real phys").font(.caption.monospaced())
                    Spacer()
                    Text(gb(real)).font(.caption.monospaced())
                        .foregroundStyle(snapshot.underRealPressure ? .orange : .secondary)
                    if snapshot.underRealPressure { Text("⚠︎ pressure").font(.caption2).foregroundStyle(.orange) }
                }
            }
            if let run {
                Divider().padding(.vertical, 2)
                Text("Measured split").font(.caption).bold()
                row("Resident floor (post-load)", run.residentFloorBytes)
                row("Activation (peak−floor)", run.activationBytes)
                row("Peak", run.peakFootprint)
                if run.retainedAfterRunBytes > 100_000_000 {   // >100 MB held past run = retention leak
                    row("⚠️ Retained after run", run.retainedAfterRunBytes)
                }
                row("Engine charge", run.engineResidentBytes)
                if !run.coResidentBackers.isEmpty {
                    Text("Co-resident: " + run.coResidentBackers.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ bytes: UInt64) -> some View {
        HStack {
            Text(label).font(.caption.monospaced())
            Spacer()
            Text(gb(bytes)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
    private func gb(_ b: UInt64) -> String { String(format: "%.2f GB", Double(b) / 1_000_000_000) }
}
