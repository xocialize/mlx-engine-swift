//
//  AdapterConformance.swift
//  MLXServeConformance
//
//  The "ADP gate" (contract 1.53.0, AB-A-0189) — the executable adjunct to typed adapters, the
//  way FIT-1..3 is to `ActivationScaling`. Offline, declarations only:
//
//    ADP-1 coherent    — every `AdapterSupport` is well-formed (a base model, formats, kinds,
//                        maxCount ≥ 1, an ordered finite strength range) and sits on a capability
//                        that carries adapters
//    ADP-2 advertised  — a surface advertises the `adapters` parameter exactly when it declares
//                        support (`declaring(adapters:)` does both)
//    ADP-3 bindable    — a `.loadTime` surface's configuration adopts `AdapterConfigured`, so the
//                        engine can build it with the requested set
//    ADP-4 catalog     — every adapter the package ships or recommends validates (pinned revision,
//                        64-hex digest, slots + footprint for a reference-conditioned adapter) and
//                        fits at least one declared surface
//
//  A manifest with no adapter declarations and no catalog passes vacuously with a single ADP-0
//  line, so every package can run the gate.
//

import Foundation
import MLXToolKit

public enum AdapterConformance {

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

    /// Check `manifest`'s adapter declarations, the `configuration` it registers with (ADP-3),
    /// and the adapter `catalog` it ships or recommends (ADP-4). Call from the package's own
    /// conformance tests:
    /// ```swift
    /// let report = AdapterConformance.check(manifest: MyPackage.manifest,
    ///                                       configuration: MyConfiguration(),
    ///                                       catalog: try MyAdapterRegistry.bundled().descriptors)
    /// XCTAssertTrue(report.passed, report.summary)
    /// ```
    public static func check(manifest: PackageManifest,
                             configuration: (any PackageConfiguration)? = nil,
                             catalog: [AdapterDescriptor] = []) -> Report {
        let declared = manifest.surfaces.filter { $0.adapters != nil }
        guard !declared.isEmpty || !catalog.isEmpty else {
            return Report(checks: [Check(name: "ADP-0 no adapters", passed: true,
                                         note: "no surface declares adapter support and no catalog was given")])
        }
        var checks: [Check] = []

        for surface in manifest.surfaces {
            let advertised = surface.parameters.contains { $0.name == "adapters" }
            guard let support = surface.adapters else {
                if advertised {
                    checks.append(Check(name: "ADP-2 advertised (\(surface.name))", passed: false,
                                        note: "advertises an `adapters` parameter but declares no "
                                            + "AdapterSupport — the engine refuses every adapter request"))
                }
                continue
            }
            var problems = support.validationProblems
            if !surface.adaptersMatchCapability {
                problems.append("declared on \(surface.capability.rawValue), which carries no adapters")
            }
            checks.append(Check(
                name: "ADP-1 coherent (\(surface.name))", passed: problems.isEmpty,
                note: problems.isEmpty
                    ? "base \(support.baseModel), \(support.formats.map(\.rawValue).joined(separator: "/")), "
                        + "kinds \(support.kinds.map(\.rawValue).joined(separator: "/")), up to "
                        + "\(support.maxCount), strength \(support.strengthRange.min)…"
                        + "\(support.strengthRange.max), \(support.binding.rawValue)"
                    : problems.joined(separator: "; ")))
            checks.append(Check(
                name: "ADP-2 advertised (\(surface.name))", passed: advertised,
                note: advertised ? "the `adapters` parameter is offered"
                    : "declares AdapterSupport but does not offer the `adapters` parameter — "
                        + "declare it with `declaring(adapters:)`"))
            if support.binding == .loadTime {
                if let configuration {
                    let bindable = configuration is AdapterConfigured
                    checks.append(Check(
                        name: "ADP-3 bindable (\(surface.name))", passed: bindable,
                        note: bindable ? "the configuration adopts AdapterConfigured"
                            : "load-time binding, but \(type(of: configuration)) does not adopt "
                                + "AdapterConfigured — the engine refuses every adapter request"))
                } else {
                    checks.append(Check(
                        name: "ADP-3 bindable (\(surface.name))", passed: false,
                        note: "load-time binding needs the configuration to check; pass it"))
                }
            }
        }

        for descriptor in catalog {
            var problems = descriptor.validationProblems
            let fits = declared.filter {
                $0.adapters?.mismatch(descriptor, capability: $0.capability) == nil
            }
            if fits.isEmpty {
                let reasons = declared.compactMap { surface in
                    surface.adapters?.mismatch(descriptor, capability: surface.capability)
                        .map { "\(surface.name): \($0)" }
                }
                problems.append("fits no declared surface"
                    + (reasons.isEmpty ? " (none declares AdapterSupport)" : " — " + reasons.joined(separator: "; ")))
            }
            checks.append(Check(
                name: "ADP-4 catalog (\(descriptor.id))", passed: problems.isEmpty,
                note: problems.isEmpty
                    ? "\(descriptor.kind) \(descriptor.format) from \(descriptor.source.repo)@"
                        + "\(descriptor.source.revision.prefix(12)), fits "
                        + fits.map(\.name).joined(separator: ", ")
                    : problems.joined(separator: "; ")))
        }
        return Report(checks: checks)
    }
}
