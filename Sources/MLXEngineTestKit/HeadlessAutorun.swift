import Foundation

/// Env-driven headless autorun — the scriptable measurement surface (the reliable one for heavy
/// packages, where a CLI bench trips the GPU watchdog but the app build has the engine's prewarm +
/// governor). An app checks `HeadlessAutorun` at launch; if active, it drives ONE generation GUI-less,
/// prints the `ValidationRun.splitLogLine`, and exits — so `xcodebuild` + a captured stdout yields the
/// measurement without the GUI.
///
/// Convention (per app, `PREFIX` = the app's short name, e.g. `LTX`, `IMAGE`):
///   `<PREFIX>_AUTORUN=1`         → autorun active
///   `<PREFIX>_VARIANT=<id>`      → which model/quant/mode to run (app-defined; "" = default)
///   `<PREFIX>_OUT=<path>`        → optional artifact output path
///
/// ```swift
/// // in the app entry point:
/// if let run = HeadlessAutorun.request(prefix: "IMAGE") {
///     Task { await runHeadless(variant: run.variant, out: run.outputPath); exit(0) }
/// }
/// ```
public enum HeadlessAutorun {
    public struct Request: Sendable {
        public let variant: String          // "" when unspecified
        public let outputPath: String?
    }

    /// Returns a `Request` when `<prefix>_AUTORUN=1` is set, else nil (normal GUI launch).
    public static func request(prefix: String) -> Request? {
        let env = ProcessInfo.processInfo.environment
        guard env["\(prefix)_AUTORUN"] == "1" else { return nil }
        return Request(variant: env["\(prefix)_VARIANT"] ?? "", outputPath: env["\(prefix)_OUT"])
    }

    /// True when any autorun is requested for `prefix` (convenience).
    public static func isActive(prefix: String) -> Bool { request(prefix: prefix) != nil }
}
