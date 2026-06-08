/// An SPDX license identifier (e.g. "MIT", "Apache-2.0").
public struct SPDXLicense: Sendable, Codable, Equatable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let identifier: String
    public init(_ identifier: String) { self.identifier = identifier }
    public init(stringLiteral value: String) { self.identifier = value }
    public var description: String { identifier }
}

extension SPDXLicense {
    public static let mit: SPDXLicense = "MIT"
    public static let apache2: SPDXLicense = "Apache-2.0"
    public static let bsd2: SPDXLicense = "BSD-2-Clause"
    public static let bsd3: SPDXLicense = "BSD-3-Clause"
    public static let isc: SPDXLicense = "ISC"
    public static let unlicense: SPDXLicense = "Unlicense"

    /// The permissive allowlist used by `.permissiveOnly`. Curated; extend deliberately.
    public static let permissiveAllowlist: Set<SPDXLicense> = [
        .mit, .apache2, .bsd2, .bsd3, .isc, .unlicense,
    ]

    public var isPermissive: Bool { SPDXLicense.permissiveAllowlist.contains(self) }
}

/// Policy the engine enforces when admitting weights and port code.
public enum LicensePolicy: Sendable, Equatable {
    case permissiveOnly
    case any

    public func admits(_ license: SPDXLicense) -> Bool {
        switch self {
        case .permissiveOnly: return license.isPermissive
        case .any: return true
        }
    }
}

/// The two-layer license declaration every package makes: the checkpoint's license (C7)
/// and the contribution's own license (C8). Constantly conflated; kept explicit here.
public struct LicenseDeclaration: Sendable, Codable, Equatable {
    public let weightLicense: SPDXLicense
    public let portCodeLicense: SPDXLicense
    public init(weightLicense: SPDXLicense, portCodeLicense: SPDXLicense) {
        self.weightLicense = weightLicense
        self.portCodeLicense = portCodeLicense
    }
}

/// The result of the gate, designed to name *which layer* failed (the C8 legibility rule).
public enum LicenseGateResult: Sendable, Equatable {
    case admitted
    case rejectedWeight(SPDXLicense)
    case rejectedPortCode(SPDXLicense)

    public var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }
}

extension LicensePolicy {
    /// Evaluate both layers; report the first failing layer together with its license,
    /// so a contributor learns *which* license and *which* layer to fix.
    public func evaluate(_ declaration: LicenseDeclaration) -> LicenseGateResult {
        guard admits(declaration.weightLicense) else {
            return .rejectedWeight(declaration.weightLicense)
        }
        guard admits(declaration.portCodeLicense) else {
            return .rejectedPortCode(declaration.portCodeLicense)
        }
        return .admitted
    }
}
