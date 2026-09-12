//
//  FootprintConformance.swift
//  MLXServeConformance
//
//  The "FIT gate" (contract 1.41.0, AB-A-0069 / AB-D-0075) — the executable adjunct to
//  `ActivationScaling`, the way MAT-1..5 is to `WeightSourcing` and LIV-1..6 is to the live-STT
//  plane. Offline, declarations only: it checks that a footprint which declares activation as a
//  function of workload is well-formed and COHERENT with the scalar admission reserves.
//
//    FIT-1 well-formed — a positive finite ceiling, a finite non-negative slope
//    FIT-2 coherent   — the reserve covers the model at the ceiling
//                       (`peakActivationBytes ≥ projectedBytes(at: measuredCeiling)`)
//    FIT-3 enforceable — a configuration registered with a scaling declaration adopts
//                       `WorkloadDeclaring`, so the ceiling can actually be enforced
//
//  A scalar-only manifest (no scaling anywhere) passes vacuously with a single FIT-0 line, so a
//  package that has nothing to declare can still run the gate and read a green summary.
//

import Foundation
import MLXToolKit

public enum FootprintConformance {

    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let note: String
    }

    public struct Report: Sendable {
        public let checks: [Check]
        public var passed: Bool { checks.allSatisfy(\.passed) }
        public var summary: String {
            checks.map { "\($0.passed ? "✅" : "❌") \($0.name) — \($0.note)" }
                .joined(separator: "\n")
        }
    }

    /// Check every quant-keyed footprint in `manifest`, and — when a `configuration` is given —
    /// the RESOLVED lane pair the engine would register (lane hints over quant-keyed, the same
    /// rule `MemoryGovernor.footprintSplit` applies) plus FIT-3. Pass the configuration: since
    /// 1.42.0 FIT-2 is a per-run guarantee for a configuration that adopts `WorkloadDeclaring`
    /// (the scalar is the representative case, a longer run reserves the projection), and only a
    /// scalar that has to stand alone must cover the model at the ceiling. Call from the
    /// package's own conformance tests:
    /// ```swift
    /// let report = FootprintConformance.check(manifest: MyPackage.manifest,
    ///                                         configuration: MyConfiguration())
    /// XCTAssertTrue(report.passed, report.summary)
    /// ```
    public static func check(manifest: PackageManifest,
                             configuration: (any PackageConfiguration)? = nil) -> Report {
        var checks: [Check] = []
        let gb = { (b: UInt64) in String(format: "%.2f GB", Double(b) / 1e9) }

        // 1.42.0: a configuration that maps workloads is covered PER RUN (admission reserves
        // max(scalar, projection)), so an uncovered pair fails FIT-2 only when nothing can map
        // a request to the line — a manifest checked alone, or a configuration without
        // `WorkloadDeclaring`.
        let perRunSized = configuration is WorkloadDeclaring
        func pair(_ label: String, scaling: ActivationScaling, reserve: UInt64) {
            let formed = scaling.isWellFormed
            checks.append(Check(
                name: "FIT-1 well-formed (\(label))", passed: formed,
                note: formed
                    ? "axis \(scaling.axis), base \(gb(scaling.baseBytes)), "
                        + "\(scaling.bytesPerUnit) B/unit, ceiling \(scaling.measuredCeiling)"
                    : "ceiling \(scaling.measuredCeiling) and slope \(scaling.bytesPerUnit) "
                        + "must be finite, ceiling > 0, slope ≥ 0"))
            guard formed else { return }
            let covered = scaling.isCovered(by: reserve)
            let note: String
            if covered {
                note = "reserve \(gb(reserve)) covers \(gb(scaling.bytesAtCeiling)) at the ceiling"
            } else if perRunSized {
                note = "reserve \(gb(reserve)) is the representative case below "
                    + "\(gb(scaling.bytesAtCeiling)) at the ceiling of \(scaling.measuredCeiling) "
                    + "\(scaling.axis); the configuration maps workloads, so a run past it "
                    + "reserves the projection per run (1.42.0) — an unmappable request reserves "
                    + "only \(gb(reserve))"
            } else {
                note = "reserve \(gb(reserve)) does NOT cover \(gb(scaling.bytesAtCeiling)) at "
                    + "the ceiling of \(scaling.measuredCeiling) \(scaling.axis) and nothing "
                    + "maps a request to the line — adopt WorkloadDeclaring, raise the reserve, "
                    + "or lower measuredCeiling to where it was measured"
            }
            checks.append(Check(name: "FIT-2 coherent (\(label))",
                                passed: covered || perRunSized, note: note))
        }

        var declared = false
        for footprint in manifest.requirements.footprints {
            guard let scaling = footprint.activationScaling else { continue }
            declared = true
            pair(footprint.quant.rawValue, scaling: scaling, reserve: footprint.peakActivationBytes)
        }

        if let configuration {
            let fc = configuration as? FootprintConfigured
            let quant = (configuration as? QuantConfigured)?.quant
            let matched = quant.flatMap { q in
                manifest.requirements.footprints.first { $0.quant == q }
            }
            let laneScaling = fc?.activationScalingHint ?? matched?.activationScaling
            if let laneScaling, fc?.activationScalingHint != nil || fc?.peakActivationBytesHint != nil {
                declared = true
                let reserve = fc?.peakActivationBytesHint ?? matched?.peakActivationBytes ?? 0
                pair("lane \(quant?.rawValue ?? "unresolved")", scaling: laneScaling,
                     reserve: reserve)
            }
            if laneScaling != nil {
                declared = true
                let enforceable = configuration is WorkloadDeclaring
                checks.append(Check(
                    name: "FIT-3 enforceable", passed: enforceable,
                    note: enforceable
                        ? "configuration adopts WorkloadDeclaring"
                        : "scaling is declared but the configuration does not adopt "
                            + "WorkloadDeclaring — the ceiling can never be enforced"))
            }
        }

        if !declared {
            checks.append(Check(name: "FIT-0 scalar-only", passed: true,
                                note: "no activation scaling declared; the scalar is the whole "
                                    + "declaration and nothing is refused"))
        }
        return Report(checks: checks)
    }
}
