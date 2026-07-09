import Foundation
import MLXToolKit

/// Offline auto-materialization contract check — the first EXECUTABLE piece of the conformance
/// suite (the "MAT gate"). No network, no weights: it verifies a package's *declarations* so
/// every engine package presents the same first-run behavior before an app ever runs it.
///
/// Call from the package's own conformance tests (the per-package suite convention):
/// ```swift
/// let report = MaterializationConformance.check(freshConfiguration: MyConfiguration())
/// XCTAssertTrue(report.passed, report.summary)
/// ```
/// Pass the configuration as a FRESH MACHINE would see it (no explicit weight paths). Optionally
/// pass a fully-satisfied configuration (explicit paths to existing files) to prove the
/// missing-set computation honors local paths.
///
/// Two source vocabularies, one gate (contract 1.17): network sources (`WeightSourcing`) are
/// required MISSING on a fresh machine; bundled sources (`BundledWeightSourcing`, vendored in the
/// binary's resource bundle) are required PRESENT. A package declares either or both — the
/// posture check (MAT-4) verifies each subset by its own rule.
public enum MaterializationConformance {

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

    public static func check(freshConfiguration: any PackageConfiguration,
                             satisfiedConfiguration: (any PackageConfiguration)? = nil) -> Report {
        var checks: [Check] = []

        // MAT-1 — the engine must be able to stamp the store root.
        let storable = freshConfiguration is ModelStorable
        checks.append(Check(name: "MAT-1 ModelStorable", passed: storable,
                            note: storable ? "engine can stamp modelsRootDirectory"
                                           : "configuration cannot receive the store root"))

        // MAT-2 — the configuration declares its sources: network (WeightSourcing), bundled
        // (BundledWeightSourcing), or both. Conforming to neither is the legacy undeclared shape.
        let sourcing = freshConfiguration as? WeightSourcing
        let bundled = freshConfiguration as? BundledWeightSourcing
        guard sourcing != nil || bundled != nil else {
            checks.append(Check(name: "MAT-2 WeightSourcing", passed: false,
                                note: "configuration declares no weight sources "
                                    + "(neither WeightSourcing nor BundledWeightSourcing)"))
            return Report(checks: checks)
        }
        let networkSources = sourcing?.weightSources ?? []
        let bundledSources = bundled?.bundledWeightSources ?? []
        let declared = networkSources.map { "\($0.role)→\($0.repo)" }
            + bundledSources.map { "\($0.role)→bundled" }
        checks.append(Check(name: "MAT-2 WeightSourcing", passed: !declared.isEmpty,
                            note: declared.isEmpty ? "empty source set"
                                                   : declared.joined(separator: ", ")))

        // MAT-3 — declaration hygiene: roles unique across BOTH vocabularies (one namespace keys
        // progress/reports), network repos well-formed "org/name".
        let roles = networkSources.map(\.role) + bundledSources.map(\.role)
        let uniqueRoles = Set(roles).count == roles.count
        let wellFormed = networkSources.allSatisfy { $0.repo.split(separator: "/").count == 2 }
        checks.append(Check(name: "MAT-3 declaration hygiene",
                            passed: uniqueRoles && wellFormed,
                            note: uniqueRoles
                                ? (wellFormed ? "roles unique, repos org/name"
                                              : "malformed repo id (want org/name)")
                                : "duplicate source roles"))

        // MAT-4 — fresh-machine posture, per vocabulary:
        //   network sources ⇒ EVERY one reports missing (nothing silently unresolvable, nothing
        //   claimed present without paths or a store);
        //   bundled sources ⇒ EVERY one resolves to a file that exists (a stripped resource must
        //   fail here, not at first inference).
        let missing = sourcing?.missingWeightSources(storeRoot: nil) ?? []
        let allMissing = Set(missing.map(\.role)) == Set(networkSources.map(\.role))
        let absentBundled = bundledSources.filter { source in
            guard let url = source.url else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        var postureNotes: [String] = []
        if !networkSources.isEmpty {
            postureNotes.append(allMissing
                ? "all \(networkSources.count) network source(s) reported missing"
                : "fresh config reports \(missing.count)/\(networkSources.count) network "
                    + "source(s) missing — must be all")
        }
        if !bundledSources.isEmpty {
            postureNotes.append(absentBundled.isEmpty
                ? "all \(bundledSources.count) bundled source(s) present"
                : "bundled source(s) unresolved/absent: "
                    + absentBundled.map(\.role).joined(separator: ", "))
        }
        checks.append(Check(name: "MAT-4 fresh-machine posture",
                            passed: allMissing && absentBundled.isEmpty,
                            note: postureNotes.joined(separator: "; ")))

        // MAT-5 (optional) — a satisfied configuration reports nothing missing. Bundled-only
        // packages have nothing to satisfy from the network; their bundled set must still resolve.
        if let satisfied = satisfiedConfiguration {
            if let satisfiedSourcing = satisfied as? WeightSourcing {
                let still = satisfiedSourcing.missingWeightSources(storeRoot: nil)
                checks.append(Check(name: "MAT-5 satisfied missing set",
                                    passed: still.isEmpty,
                                    note: still.isEmpty ? "explicit paths satisfy all sources"
                                        : "still missing: \(still.map(\.role).joined(separator: ", "))"))
            } else if let satisfiedBundled = satisfied as? BundledWeightSourcing {
                let unresolved = satisfiedBundled.bundledWeightSources.filter { source in
                    guard let url = source.url else { return true }
                    return !FileManager.default.fileExists(atPath: url.path)
                }
                checks.append(Check(name: "MAT-5 satisfied missing set",
                                    passed: unresolved.isEmpty,
                                    note: unresolved.isEmpty
                                        ? "bundled-only: nothing to satisfy from the network"
                                        : "bundled source(s) unresolved/absent: "
                                            + unresolved.map(\.role).joined(separator: ", ")))
            } else {
                checks.append(Check(name: "MAT-5 satisfied missing set", passed: false,
                                    note: "satisfied configuration declares no weight sources"))
            }
        }
        return Report(checks: checks)
    }
}
