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

    /// bilibili's IndexTTS2 model license (INDEX_MODEL_LICENSE). Non-SPDX, referenced via
    /// `LicenseRef-`. **NON-permissive** — personal / research / educational use permitted;
    /// commercial use requires bilibili's separate written authorization. Deliberately NOT on
    /// `permissiveAllowlist`; admitted ONLY under `.permissiveOrAcknowledged` as an explicit
    /// eval/personal-use opt-in (same pattern as Anima). The port code (mlx-indextts2-swift,
    /// donor solar2ain/mlx-indextts) is Apache-2.0/MIT — only the weights carry this license.
    /// Used by the IndexTTS2 emotion+duration TTS port (IndexTTS2Package).
    public static let indexTTS2Model: SPDXLicense = "LicenseRef-Index-Model"

    /// NVIDIA Open Model License Agreement (v. June 14, 2024). Non-SPDX, referenced via the
    /// `LicenseRef-` convention. Reviewed against the full agreement text: **commercially
    /// permissive** — "Models are commercially useable"; §2.2 grants a perpetual, worldwide,
    /// royalty-free license to reproduce, create derivatives, make, **sell, offer for sale,
    /// distribute and import**; §3 permits redistribution of the Model and Derivative Models in
    /// any medium with or without modification; §2.4 — NVIDIA claims **no ownership of outputs**
    /// and You own Your Derivative Models. **No revenue/MAU threshold, no non-compete, no
    /// eval-only clause** — strictly *less* restrictive than the allowlisted `ltx2Community`
    /// (revenue gate + non-compete) and the same shape as the allowlisted `dinov3`/`gemmaTerms`
    /// (commercial + attribution + AUP). The only binds are: §3.1 — when **distributing the
    /// weights**, ship a copy of the Agreement plus a "Notice" file reading "Licensed by NVIDIA
    /// Corporation under the NVIDIA Open Model License"; a §2.3 AI-ethics AUP; §4 no trademark
    /// grant; §10 export compliance; and a §2.1 defensive-patent termination (same shape as
    /// Apache-2.0 §3). On that basis this project **permits** it. Used by the NVIDIA NanoCodec
    /// vocoder weights in the Gepard streaming-TTS port (GepardPackage); honor the §3.1 Notice
    /// wherever the codec weights are shipped.
    public static let nvidiaOpenModel: SPDXLicense = "LicenseRef-NVIDIA-Open-Model"

    /// Linux Foundation OpenMDW License v1.1 (openmdw.ai/license/1-1). Referenced by its official
    /// name (SPDX inclusion pending at review time). Reviewed against the license text:
    /// **maximally permissive** — grants free-of-charge permission to "deal in the Model Materials
    /// without restriction" under all copyright, patent, database, and trade secret rights; no
    /// field-of-use, revenue, or geographic restriction; **no restrictions or obligations on
    /// outputs**. The only binds are: retain the agreement text + notices of origin when
    /// distributing Model Materials (attribution, same shape as MIT), and a defensive-patent/
    /// copyright termination (same shape as Apache-2.0 §3). Strictly less restrictive than
    /// several allowlisted entries (`ltx2Community`, `dinov3`, `gemmaTerms`), so this project
    /// **permits** it. Used by the NVIDIA Nemotron 3.5 ASR streaming weights in the STT port
    /// (NemotronSTTPackage); NVIDIA adopted OpenMDW across the Nemotron/Cosmos/GR00T families.
    public static let openMDW1_1: SPDXLicense = "OpenMDW-1.1"

    /// Liquid AI's LFM Open License v1.0 (liquid.ai/lfm-license; the LICENSE file on the
    /// LiquidAI HF repos). Non-SPDX, referenced via the `LicenseRef-` convention. Reviewed
    /// against the license text (2026-07-24): **Apache-2.0-derived** — broad, royalty-free,
    /// perpetual rights to use, modify, and distribute the models and Derivatives, commercial
    /// use included; no field-of-use restriction, no non-compete, no eval-only clause, no
    /// output claims. The single carve-out is a **revenue gate**: once an entity's annual
    /// revenue exceeds $10M USD its commercial-use rights under the free license end and a
    /// commercial license from Liquid AI is required (research use stays free). That is the
    /// same shape as the allowlisted `ltx2Community` (revenue gate + non-compete + derivative
    /// terms) MINUS the non-compete — strictly less restrictive — so this project **permits**
    /// it under the same rationale. The pass is CONDITIONAL on the $10M threshold: record it
    /// wherever LFM weights ship and revisit at crossing (a conditional-pass C7, not a clean
    /// one). Used by the LFM2.5-8B-A1B `llm` package (LFMLLMPackage).
    public static let lfmOpen1: SPDXLicense = "LicenseRef-LFM-Open-1.0"

    /// The permissive allowlist used by `.permissiveOnly`. Curated; extend deliberately.
    public static let permissiveAllowlist: Set<SPDXLicense> = [
        .mit, .apache2, .bsd2, .bsd3, .isc, .unlicense, .funasrModel, .ccBy4, .ltx2Community, .dinov3,
        .gemmaTerms, .nvidiaOpenModel, .openMDW1_1, .lfmOpen1,
    ]

    /// Non-permissive licenses explicitly acknowledged for **eval/research** use only. These are
    /// NOT permissive (copyleft, non-compete, or otherwise non-shippable) and are admitted solely
    /// under `.permissiveOrAcknowledged`, never under the default `.permissiveOnly`. Each entry is a
    /// deliberate, auditable opt-in — extend only when a port is gated to evaluation, never for
    /// shippable capabilities.
    /// - `circleStoneNonCommercial`: the Anima anime-T2I weights (personal/research use only).
    /// - `indexTTS2Model`: the IndexTTS2 TTS weights (commercial use needs bilibili written
    ///   authorization).
    public static let evalAcknowledgedAllowlist: Set<SPDXLicense> = [
        .circleStoneNonCommercial, .indexTTS2Model,
    ]

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

/// Whether a non-admitted license *blocks* registration or is merely reported.
///
/// **Default is `.advisory` since contract 1.28.0** (decided 2026-07-26). C7/C8 began life as hard
/// blockers to stop early, careless mistakes while the fleet was small and the reviewer was learning
/// which model licenses were shippable. That job is done — 41 published packages later, each license
/// in `permissiveAllowlist` carries a reviewed rationale — and the blocker now costs more than it
/// buys: it turns a *documentation* problem (an unreviewed license) into a *runtime* failure, in the
/// one component every package depends on.
///
/// So the requirement changes shape, not substance: **both layers must still be declared** (that is
/// what C7/C8 assert, and a reviewer still checks them), and the engine still *classifies* every
/// declaration against the policy and reports what it finds — it just no longer refuses to run.
/// Nothing about license diligence is relaxed; the enforcement point moves from load-time to review.
///
/// Opt back in with `.blocking` when a build genuinely must not load non-permissive weights — a
/// commercial distribution, or a CI job asserting the fleet stays clean. The mechanism is unchanged
/// and fully tested; only the default flipped.
public enum LicenseEnforcement: Sendable, Equatable {
    /// Register anyway; record the finding on `MLXServeEngine.licenseAdvisories` and log it.
    case advisory
    /// Throw `EngineError.licenseRejected`, naming the failing layer (the pre-1.28.0 behavior).
    case blocking
}

/// A license finding the engine recorded but did not act on (`.advisory` enforcement).
///
/// Consuming apps can surface these — "these weights are non-commercial" is exactly the kind of
/// thing a user should see in a model list, and it is more useful shown than thrown.
public struct LicenseAdvisory: Sendable, Equatable {
    /// Which layer of the two-layer declaration was not admitted.
    public enum Layer: String, Sendable, Equatable, Codable {
        case weight, portCode
    }

    /// The source repo of the package that declared it (`provenance.sourceRepo`).
    public let repo: String
    /// The layer that fell outside the policy.
    public let layer: Layer
    /// The license that layer declared.
    public let license: SPDXLicense
    /// The policy it was judged against, so a reader knows what "not admitted" meant here.
    public let policy: LicensePolicy

    public init(repo: String, layer: Layer, license: SPDXLicense, policy: LicensePolicy) {
        self.repo = repo
        self.layer = layer
        self.license = license
        self.policy = policy
    }

    /// One-line, reviewer-legible summary.
    public var summary: String {
        "\(repo): \(layer == .weight ? "weight" : "port-code") license \(license) is outside "
            + "\(policy) — declared and allowed to load (advisory enforcement)."
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
///
/// Under `.advisory` enforcement a `rejected…` result is **not** a refusal — it is a classification
/// the engine records as a `LicenseAdvisory`. The case names predate the enforcement split and are
/// kept for source compatibility.
public enum LicenseGateResult: Sendable, Equatable {
    case admitted
    case rejectedWeight(SPDXLicense)
    case rejectedPortCode(SPDXLicense)

    public var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }

    /// The finding as an advisory, or `nil` when the declaration was admitted.
    public func advisory(repo: String, policy: LicensePolicy) -> LicenseAdvisory? {
        switch self {
        case .admitted:
            return nil
        case .rejectedWeight(let license):
            return LicenseAdvisory(repo: repo, layer: .weight, license: license, policy: policy)
        case .rejectedPortCode(let license):
            return LicenseAdvisory(repo: repo, layer: .portCode, license: license, policy: policy)
        }
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
