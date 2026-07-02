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

        // MAT-2 — the configuration declares its sources.
        guard let sourcing = freshConfiguration as? WeightSourcing else {
            checks.append(Check(name: "MAT-2 WeightSourcing", passed: false,
                                note: "configuration does not declare weight sources"))
            return Report(checks: checks)
        }
        let sources = sourcing.weightSources
        checks.append(Check(name: "MAT-2 WeightSourcing", passed: !sources.isEmpty,
                            note: sources.isEmpty ? "empty source set"
                                : sources.map { "\($0.role)→\($0.repo)" }.joined(separator: ", ")))

        // MAT-3 — declaration hygiene: unique roles, well-formed "org/name" repos.
        let roles = sources.map(\.role)
        let uniqueRoles = Set(roles).count == roles.count
        let wellFormed = sources.allSatisfy { $0.repo.split(separator: "/").count == 2 }
        checks.append(Check(name: "MAT-3 declaration hygiene",
                            passed: uniqueRoles && wellFormed,
                            note: uniqueRoles
                                ? (wellFormed ? "roles unique, repos org/name"
                                              : "malformed repo id (want org/name)")
                                : "duplicate source roles"))

        // MAT-4 — fresh machine ⇒ EVERY declared source reports missing (nothing silently
        // unresolvable, nothing claimed present without paths or a store).
        let missing = sourcing.missingWeightSources(storeRoot: nil)
        let allMissing = Set(missing.map(\.role)) == Set(roles)
        checks.append(Check(name: "MAT-4 fresh-machine missing set",
                            passed: allMissing,
                            note: allMissing ? "all \(sources.count) source(s) reported missing"
                                : "fresh config reports \(missing.count)/\(sources.count) missing — must be all"))

        // MAT-5 (optional) — a satisfied configuration reports nothing missing.
        if let satisfied = satisfiedConfiguration {
            if let satisfiedSourcing = satisfied as? WeightSourcing {
                let still = satisfiedSourcing.missingWeightSources(storeRoot: nil)
                checks.append(Check(name: "MAT-5 satisfied missing set",
                                    passed: still.isEmpty,
                                    note: still.isEmpty ? "explicit paths satisfy all sources"
                                        : "still missing: \(still.map(\.role).joined(separator: ", "))"))
            } else {
                checks.append(Check(name: "MAT-5 satisfied missing set", passed: false,
                                    note: "satisfied configuration is not WeightSourcing"))
            }
        }
        return Report(checks: checks)
    }
}
