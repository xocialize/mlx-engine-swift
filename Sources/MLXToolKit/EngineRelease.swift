/// The mlx-engine-swift release this build of MLXToolKit belongs to (AB-A-0248).
///
/// `ContractVersion.current` is the capability contract; this is the tagged release a package or
/// plugin actually linked, so a manifest can name the engine it resolved at runtime. Bumped with
/// each tag — `Scripts/status-block-lint.py` fails when it differs from the README status block's
/// tag, which it already asserts equals the newest tag reachable from HEAD.
public enum MLXEngineRelease {
    /// The release version without the leading `v` (`"0.75.0"` for tag `v0.75.0`).
    public static let version = "0.75.0"
    /// The capability contract of this release (`ContractVersion.current`, as text).
    public static var contract: String { ContractVersion.current.description }
}
