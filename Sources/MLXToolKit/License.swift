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

    /// FunASR's custom model license (used by the emotion2vec / emotion2vec+ checkpoints).
    /// Non-SPDX, so referenced via the SPDX `LicenseRef-` convention. It permits use, copy,
    /// modification, and redistribution with attribution and model-name retention (plus a
    /// no-denigration clause and no warranty) — functionally permissive, hence allowlisted.
    public static let funasrModel: SPDXLicense = "LicenseRef-FunASR-Model"

    /// Creative Commons Attribution 4.0 — permissive (commercial use + redistribution allowed,
    /// attribution required; no share-alike, no non-commercial clause). Used by model weights such
    /// as Kyutai's Mimi codec. A recognized SPDX id.
    public static let ccBy4: SPDXLicense = "CC-BY-4.0"

    /// Lightricks LTX-2 Community License. Non-SPDX, referenced via the `LicenseRef-` convention.
    /// Source-available with a §2 revenue gate (≥$10M entities need a paid license), §3 derivative
    /// terms, and a §A.20 non-compete. Reviewed against the actual license text and Lightricks' own
    /// open-source LTX-Desktop, which licenses its *inference code* (`ltx-core`, `ltx-pipelines`)
    /// as Apache-2.0 — only the weights carry the Community License. On that basis this project
    /// **permits** the license: it lives on `permissiveAllowlist` and is admitted by the default
    /// `.permissiveOnly` policy.
    public static let ltx2Community: SPDXLicense = "LicenseRef-LTX-2-Community"

    /// The permissive allowlist used by `.permissiveOnly`. Curated; extend deliberately.
    public static let permissiveAllowlist: Set<SPDXLicense> = [
        .mit, .apache2, .bsd2, .bsd3, .isc, .unlicense, .funasrModel, .ccBy4, .ltx2Community,
    ]

    /// Non-permissive licenses explicitly acknowledged for **eval/research** use only. These are
    /// NOT permissive (copyleft, non-compete, or otherwise non-shippable) and are admitted solely
    /// under `.permissiveOrAcknowledged`, never under the default `.permissiveOnly`. Each entry is a
    /// deliberate, auditable opt-in — extend only when a port is gated to evaluation, never for
    /// shippable capabilities. Currently empty: generic infrastructure for a future eval-gated port.
    public static let evalAcknowledgedAllowlist: Set<SPDXLicense> = []

    public var isPermissive: Bool { SPDXLicense.permissiveAllowlist.contains(self) }

    /// Whether this license is on the eval/research acknowledged list. Distinct from `isPermissive`:
    /// an acknowledged license is explicitly NOT permissive — it passes only the looser eval policy.
    public var isEvalAcknowledged: Bool { SPDXLicense.evalAcknowledgedAllowlist.contains(self) }
}

/// Policy the engine enforces when admitting weights and port code.
public enum LicensePolicy: Sendable, Equatable {
    /// Default product policy: only the curated permissive allowlist.
    case permissiveOnly
    /// Eval/research policy: permissive licenses plus the explicitly acknowledged eval-only set
    /// (`evalAcknowledgedAllowlist`). Use for engines that host gated, non-shippable specialty
    /// ports (e.g. LTX-2). Still rejects anything not on either list.
    case permissiveOrAcknowledged
    /// No gate — admits any license.
    case any

    public func admits(_ license: SPDXLicense) -> Bool {
        switch self {
        case .permissiveOnly: return license.isPermissive
        case .permissiveOrAcknowledged: return license.isPermissive || license.isEvalAcknowledged
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
