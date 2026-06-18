//
//  ModelStateView.swift
//  MLXEngineUI
//
//  A reusable, engine-provided strip that surfaces a capability's preparation state — the consistent
//  "downloading weights (progress + speed) / first load is heavy, one-time / ready" affordance every
//  consuming app gets for free instead of building its own. Bind it to `MLXServeEngine.preparation`.
//

import SwiftUI
import MLXToolKit

/// Renders the current `PreparePhase` for a capability from an engine `PreparationMonitor`. Host it
/// inline (e.g. above a "Run" button) — it updates live as `prepare()` progresses.
///
/// ```swift
/// ModelStateView(monitor: engine.preparation, capability: .imageRestore, title: "NAFNet · SIDD")
/// ```
public struct ModelStateView: View {
    private let monitor: PreparationMonitor
    private let capability: Capability
    private let package: String?
    private let title: String?

    public init(monitor: PreparationMonitor,
                capability: Capability,
                package: String? = nil,
                title: String? = nil) {
        self.monitor = monitor
        self.capability = capability
        self.package = package
        self.title = title
    }

    public var body: some View {
        let phase = monitor.phase(for: capability, package: package)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title ?? capability.rawValue)
                    .font(MarqueeFont.bodyMedium)
                    .foregroundStyle(MarqueeColor.textPrimary)
                Spacer()
                statusLabel(phase)
            }

            if let fraction = determinate(phase) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(MarqueeColor.accentBlue)
            } else if isIndeterminate(phase) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(MarqueeColor.accentBlue)
            }

            if let caption = caption(phase) {
                Text(caption)
                    .font(MarqueeFont.caption)
                    .foregroundStyle(MarqueeColor.textMuted)
            }
        }
        .padding(12)
        .background(MarqueeColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.groupCornerRadius))
    }

    // MARK: - Phase → UI

    @ViewBuilder
    private func statusLabel(_ phase: PreparePhase) -> some View {
        switch phase {
        case .idle:
            Text("Not loaded").font(MarqueeFont.caption).foregroundStyle(MarqueeColor.textMuted)
        case .registering:
            Text("Preparing…").font(MarqueeFont.caption).foregroundStyle(MarqueeColor.textSecondary)
        case let .prewarming(fraction):
            Text("Warming \(percent(fraction))")
                .font(MarqueeFont.caption).foregroundStyle(MarqueeColor.textSecondary)
        case let .downloading(fraction, bps):
            Text("Downloading \(percent(fraction))\(speedSuffix(bps))")
                .font(MarqueeFont.caption).foregroundStyle(MarqueeColor.accentBlue)
        case .loading:
            Text("Loading…").font(MarqueeFont.caption).foregroundStyle(MarqueeColor.textSecondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(MarqueeFont.caption).foregroundStyle(MarqueeColor.success)
        case let .failed(reason):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(MarqueeFont.caption).foregroundStyle(MarqueeColor.error)
                .help(reason)
        }
    }

    /// A determinate [0,1] fraction for the phases that have one.
    private func determinate(_ phase: PreparePhase) -> Double? {
        switch phase {
        case let .prewarming(f), let .downloading(f, _): return max(0, min(1, f))
        default: return nil
        }
    }

    private func isIndeterminate(_ phase: PreparePhase) -> Bool {
        switch phase {
        case .registering, .loading: return true
        default: return false
        }
    }

    private func caption(_ phase: PreparePhase) -> String? {
        switch phase {
        case .downloading: return "First load downloads the weights — one-time."
        case .prewarming:  return "Warming weights into memory — one-time per cold start."
        case .loading:     return "First load is heavy; subsequent loads are fast."
        case let .failed(reason): return reason
        default:           return nil
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    private func speedSuffix(_ bytesPerSecond: Double?) -> String {
        guard let bps = bytesPerSecond, bps > 0 else { return "" }
        return " · \(formatRate(bps))"
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        let mbps = bytesPerSecond / 1_000_000
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }
}
