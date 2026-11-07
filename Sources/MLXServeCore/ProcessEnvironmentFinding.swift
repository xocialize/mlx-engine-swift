import Foundation

/// A package's declared process-environment requirement (`RequirementsManifest.processEnvironment`,
/// contract 1.60.0, AB-A-0215) that the process contradicts: `name` was already set to `actual`, not
/// the `required` value. See `MLXServeEngine.processEnvironmentFindings`.
public struct ProcessEnvironmentFinding: Sendable, Equatable, Hashable {
    public let name: String
    public let required: String
    public let actual: String
    /// The declaring package's `provenance.sourceRepo`.
    public let requiredBy: String

    public init(name: String, required: String, actual: String, requiredBy: String) {
        self.name = name
        self.required = required
        self.actual = actual
        self.requiredBy = requiredBy
    }
}
