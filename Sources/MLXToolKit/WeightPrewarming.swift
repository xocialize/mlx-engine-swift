import Foundation

/// A `PackageConfiguration` that declares the weight files/directories the engine should page into
/// the OS file cache **before** the package's `load()` runs its GPU evals.
///
/// **Cold-start watchdog mitigation — model lifecycle is the engine's job.** On a cold file cache,
/// loading a large model off slow / external storage can stall a Metal command buffer *inside* a
/// load-time `eval` while it faults weights in from disk, tripping
/// `kIOGPUCommandBufferCallbackErrorTimeout` — an uncatchable GPU abort on the completion thread.
/// By paging the weights into cache first, the file-I/O latency is moved OUT of any live command
/// buffer. This is the in-engine replacement for the manual `cat`-warm workaround.
///
/// **Opt-in + best-effort.** Configurations that don't conform are loaded unchanged; a prewarm
/// failure never fails `prepare()`. Only the configuration knows its resolved (often absolute /
/// external-volume) weight paths, so the configuration is the authority that *declares* them — the
/// engine owns the *execution* (`WeightPrewarmer`, run before `load()`).
///
/// Example:
/// ```swift
/// extension MyConfiguration: WeightPrewarming {
///     public var prewarmPaths: [URL] {
///         [modelDirectory, transformerPath].compactMap { $0 }   // dirs are scanned; files pass through
///     }
/// }
/// ```
public protocol WeightPrewarming {
    /// Files and/or directories to page into the OS cache before `load()`. Directories are scanned
    /// recursively for weight files (`.safetensors`, `.gguf`, …); plain files are paged as-is.
    /// Missing / empty paths are skipped. Order is preserved; duplicates are de-duped.
    var prewarmPaths: [URL] { get }
}
