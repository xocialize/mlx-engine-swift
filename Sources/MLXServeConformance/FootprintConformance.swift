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
    /// rule `MemoryGovernor.footprintSplit` applies) plus FIT-3. Call from the package's own
    /// conformance tests:
    /// ```swift
    /// let report = FootprintConformance.check(manifest: MyPackage.manifest,
    ///                                         configuration: MyConfiguration())
    /// XCTAssertTrue(report.passed, report.summary)
    /// ```
    public static func check(manifest: PackageManifest,
                             configuration: (any PackageConfiguration)? = nil) -> Report {
        var checks: [Check] = []
        let gb = { (b: UInt64) in String(format: "%.2f GB", Double(b) / 1e9) }

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
            checks.append(Check(
                name: "FIT-2 coherent (\(label))", passed: covered,
                note: covered
                    ? "reserve \(gb(reserve)) covers \(gb(scaling.bytesAtCeiling)) at the ceiling"
                    : "reserve \(gb(reserve)) does NOT cover \(gb(scaling.bytesAtCeiling)) at "
                        + "the ceiling of \(scaling.measuredCeiling) \(scaling.axis) — raise "
                        + "the reserve or lower measuredCeiling to where it was measured"))
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
