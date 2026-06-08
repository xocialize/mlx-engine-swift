// MLXToolKit — the MLXEngine contract surface.
//
// MLXEngine is a runtime *coordinator*, not an inference engine. Packages do inference;
// the engine instantiates, holds, drives, and evicts them (inversion of control). These
// types are the contract a package conforms to so the engine can own its lifecycle and
// expose it uniformly. Build via Xcode / xcodebuild (macOS 26.2+).

/// A simple semantic version.
public struct SemanticVersion: Sendable, Codable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The conformance-contract version this build of MLXToolKit defines.
///
/// Every conformant package declares the contract version it targets (C0). The contract is
/// additive at minor versions; breaking changes bump the major and carry a deprecation window.
public enum ContractVersion {
    public static let current = SemanticVersion(major: 1, minor: 0, patch: 0)
}
