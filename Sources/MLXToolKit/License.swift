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

    /// Meta's DINOv3 License. Non-SPDX, referenced via the `LicenseRef-` convention. Reviewed against
    /// the license text (ai.meta.com/resources/models-and-libraries/dinov3-license): commercial use
    /// and redistribution are permitted, with **no revenue/MAU threshold and no non-compete** — the
    /// obligations are attribution ("Built with DINOv3" displayed prominently), shipping a copy of the
    /// license with distributed materials, and a standard acceptable-use policy (no military/weapons/
    /// ITAR). That is functionally permissive and *less* restrictive than `ltx2Community` (which carries
    /// a revenue gate + non-compete yet is allowlisted), so this project **permits** it. Used by the
    /// DINOv3 conditioner weights in the TRELLIS.2 image→3D port. Honor the "Built with DINOv3"
    /// attribution wherever the conditioner is shipped.
    public static let dinov3: SPDXLicense = "LicenseRef-DINOv3"

    /// Google's Gemma Terms of Use (ai.google.dev/gemma/terms). Non-SPDX, referenced via the
    /// `LicenseRef-` convention. Reviewed against the terms text (2026-07-02): commercial use is
    /// permitted (§2.2); redistribution and Model Derivatives are permitted with obligations —
    /// pass the §3.2 use restrictions downstream, ship a copy of the Agreement, mark modified
    /// files, and carry the "Gemma is provided under and subject to the Gemma Terms of Use…"
    /// notice on non-hosted distributions (§3.1). Google claims no rights in Outputs (§3.3).
    /// **No revenue/MAU threshold, no non-compete, no eval-only clause** — the only bind is the
    /// Gemma Prohibited Use Policy (an AUP, §3.2). That is functionally permissive-with-AUP,
    /// strictly less restrictive than the allowlisted `ltx2Community` (revenue gate + non-compete)
    /// and the same shape as the allowlisted `dinov3` (attribution + AUP), so this project
    /// **permits** it. Honor the notice + terms-passthrough wherever Gemma weights are shipped.
    /// Used by the Gemma-3 `llm` package (GemmaLLMPackage) and the LTX-2.3 text encoder layer.
    public static let gemmaTerms: SPDXLicense = "LicenseRef-Gemma-Terms"

    /// CircleStone Labs' Anima Non-Commercial license. Non-SPDX, referenced via `LicenseRef-`.
    /// **NON-permissive** — personal / research use only, no commercial use (the base denoiser is
    /// "Built on NVIDIA Cosmos" under the Cosmos Open Model License). Deliberately NOT on
    /// `permissiveAllowlist`; admitted ONLY under `.permissiveOrAcknowledged` as an explicit
    /// eval/personal-use opt-in. Used by the Anima anime-T2I port (AnimaT2IPackage).
    public static let circleStoneNonCommercial: SPDXLicense = "LicenseRef-CircleStone-NonCommercial"

    /// The permissive allowlist used by `.permissiveOnly`. Curated; extend deliberately.
    public static let permissiveAllowlist: Set<SPDXLicense> = [
        .mit, .apache2, .bsd2, .bsd3, .isc, .unlicense, .funasrModel, .ccBy4, .ltx2Community, .dinov3,
        .gemmaTerms,
    ]

    /// Non-permissive licenses explicitly acknowledged for **eval/research** use only. These are
    /// NOT permissive (copyleft, non-compete, or otherwise non-shippable) and are admitted solely
    /// under `.permissiveOrAcknowledged`, never under the default `.permissiveOnly`. Each entry is a
    /// deliberate, auditable opt-in — extend only when a port is gated to evaluation, never for
    /// shippable capabilities.
    /// - `circleStoneNonCommercial`: the Anima anime-T2I weights (personal/research use only).
    public static let evalAcknowledgedAllowlist: Set<SPDXLicense> = [.circleStoneNonCommercial]

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
