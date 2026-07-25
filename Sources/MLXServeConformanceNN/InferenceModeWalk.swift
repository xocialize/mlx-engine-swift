import Foundation
import MLXNN
import MLXServeConformance

// The MLXNN half of the INF gate (C14). It lives in its own target so `MLXServeConformance` stays
// MLX-free — `mlx-audio-polish-swift` is a real MLX-free consumer of the conformance suite (the
// deliberate non-MLX capability seam: Accelerate DSP, no weights, no GPU), and a functional port
// declaring `.notApplicable` needs no MLXNN either. Packages that DO hold an `MLXNN.Module` graph
// add this one product to their test/gate target.
//
// The walk is shared here rather than written per package on purpose: a hand-rolled walk is
// exactly the kind of code the gate exists to stop being hand-rolled. What a package must still
// write is the *reach* into its own graph (`InferenceModeInspectable`) — nobody else can know
// where its models live.

extension InferenceModeConformance {

    /// Flatten one `MLXNN.Module` graph into `ModuleTrainingFlag`s.
    ///
    /// Uses `Module.namedModules()`, which visits the whole tree **including the root** (the root
    /// arrives with an empty key and is reported as `<root>`, or as `prefix` when one is given).
    /// Visiting every node — not just the leaves, and not just the norm layers — is the point:
    /// `train(_:)` is recursive, so a single module still reporting `training == true` means the
    /// call never covered that subtree.
    ///
    /// - Parameters:
    ///   - model: the loaded graph. `nil` yields `[]`, which INF-1 fails under `.moduleGraph` —
    ///     the intended outcome for a gate run before `load()`.
    ///   - prefix: role label for a package that loads several components, so paths stay
    ///     attributable (`campplus.xvector.bn1` rather than a second anonymous `bn1`).
    public static func flags(of model: Module?, prefix: String = "") -> [ModuleTrainingFlag] {
        guard let model else { return [] }
        return model.namedModules().map { path, module in
            ModuleTrainingFlag(path: qualify(path: path, prefix: prefix),
                               type: "\(type(of: module))",
                               training: module.training)
        }
    }

    /// Flatten several separately-loaded components at once — the common shape for a pipeline that
    /// holds a DiT plus a text encoder plus a VAE, or IndexTTS2's seven. Keys become path prefixes;
    /// components are emitted in sorted key order so a failure note is stable across runs.
    ///
    /// ```swift
    /// InferenceModeConformance.flags(of: ["gpt": gpt, "campplus": campplus, "bigvgan": bigvgan])
    /// ```
    public static func flags(of components: [String: Module?]) -> [ModuleTrainingFlag] {
        components
            .sorted { $0.key < $1.key }
            .flatMap { flags(of: $0.value, prefix: $0.key) }
    }

    private static func qualify(path: String, prefix: String) -> String {
        switch (path.isEmpty, prefix.isEmpty) {
        case (true, true):   return "<root>"
        case (true, false):  return prefix
        case (false, true):  return path
        case (false, false): return "\(prefix).\(path)"
        }
    }
}
