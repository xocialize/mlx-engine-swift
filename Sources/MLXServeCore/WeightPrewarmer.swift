import Foundation
import MLXToolKit
#if canImport(Darwin)
import Darwin
#endif

/// Engine-owned execution of the cold-start weight prewarm (see `WeightPrewarming` in MLXToolKit).
/// Pages a package's declared weight files into the OS unified buffer cache **before** `load()`
/// issues its GPU evals, so disk-I/O latency never sits inside a live Metal command buffer (the
/// `kIOGPUCommandBufferCallbackErrorTimeout` cold-load abort).
///
/// **Best-effort:** every failure is swallowed — prewarming must never fail `prepare()`. Disable
/// entirely with `MLXENGINE_DISABLE_PREWARM=1` (for cold/warm A/B measurement).
enum WeightPrewarmer {
    /// Weight-file extensions worth paging in. Small sidecars (config/tokenizer/json) load fast and
    /// aren't the watchdog risk, so directory scans only pull these.
    private static let weightExtensions: Set<String> = [
        "safetensors", "gguf", "bin", "pt", "pth", "npz", "mlx", "weights",
    ]

    private static var isDisabled: Bool {
        ProcessInfo.processInfo.environment["MLXENGINE_DISABLE_PREWARM"] == "1"
    }

    /// Page `paths` (files and/or directories) into the file cache, returning when resident. Runs the
    /// blocking reads on a detached task so the `InferenceActor`'s executor isn't stalled. `onProgress`
    /// (if given) is called with the fraction read `[0, 1]`, throttled to ~1% steps.
    static func prewarm(_ paths: [URL],
                        label: String,
                        onProgress: (@Sendable (Double) -> Void)? = nil) async {
        guard !isDisabled, !paths.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            let files = expand(paths)
            guard !files.isEmpty else { return }
            let total = files.reduce(UInt64(0)) { $0 &+ (fileSize($1) ?? 0) }
            let start = Date()
            var done: UInt64 = 0
            var lastReported = -1.0
            for url in files {
                warmFile(url) { chunk in
                    done &+= chunk
                    guard let onProgress, total > 0 else { return }
                    let f = min(Double(done) / Double(total), 1.0)
                    if f - lastReported >= 0.01 { lastReported = f; onProgress(f) }
                }
            }
            onProgress?(1.0)
            let secs = Date().timeIntervalSince(start)
            print(String(format: "[Prewarm] %@: paged %d file(s) / %.1f GB into cache in %.1fs",
                         label, files.count, Double(done) / 1_000_000_000, secs))
        }.value
    }

    /// Expand directories to their weight files (recursive); pass plain files through. De-duped,
    /// order-stable. Missing paths are skipped.
    private static func expand(_ paths: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                guard let e = fm.enumerator(at: path, includingPropertiesForKeys: keys) else { continue }
                for case let item as URL in e {
                    guard weightExtensions.contains(item.pathExtension.lowercased()) else { continue }
                    if seen.insert(item.path).inserted { out.append(item) }
                }
            } else if seen.insert(path.path).inserted {
                out.append(path)
            }
        }
        return out
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_size > 0 else { return nil }
        return UInt64(st.st_size)
    }

    /// Page one file into cache: kick async kernel readahead (`F_RDADVISE`, no userspace copy), then a
    /// blocking sequential read to *guarantee* residency — the in-process equivalent of `cat`-warming.
    /// `onChunk` is called with each chunk's byte count (for progress).
    private static func warmFile(_ url: URL, onChunk: (UInt64) -> Void) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return }

        #if canImport(Darwin)
        var ra = radvisory(ra_offset: 0,
                           ra_count: Int32(truncatingIfNeeded: min(st.st_size, Int64(Int32.max))))
        _ = fcntl(fd, F_RDADVISE, &ra)
        #endif

        let chunk = 8 * 1024 * 1024
        var buf = [UInt8](repeating: 0, count: chunk)
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while true {
                let n = read(fd, base, chunk)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                onChunk(UInt64(n))
            }
        }
    }
}
