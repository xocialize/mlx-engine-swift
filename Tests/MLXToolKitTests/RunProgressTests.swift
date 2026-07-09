import XCTest
@testable import MLXToolKit

@MainActor
final class RunProgressTests: XCTestCase {

    // MARK: - RunProgress (ambient sink)

    func testReportIsNoOpWhenUnbound() {
        // Must not crash and must not require any setup — a package reports unconditionally.
        RunProgress.report(.denoise, step: 1, totalSteps: 8)
        RunProgress.report(RunPhaseReport(phase: .decode))
    }

    func testReportForwardsToBoundSink() {
        final class Box: @unchecked Sendable { var items: [RunPhaseReport] = [] }
        let box = Box()
        let sink: RunProgress.Sink = { box.items.append($0) }
        RunProgress.$sink.withValue(sink) {
            RunProgress.report(.encode)
            RunProgress.report(.denoise, step: 3, totalSteps: 8, stage: 1, totalStages: 2)
            RunProgress.report(RunPhaseReport(phase: .decode, step: 2, totalSteps: 5))
        }
        // Unbound again outside the scope → no-op.
        RunProgress.report(.postprocess)

        XCTAssertEqual(box.items.count, 3)
        XCTAssertEqual(box.items[0], RunPhaseReport(phase: .encode))
        XCTAssertEqual(box.items[1],
                       RunPhaseReport(phase: .denoise, step: 3, totalSteps: 8, stage: 1, totalStages: 2))
        XCTAssertEqual(box.items[2].phase, .decode)
        XCTAssertEqual(box.items[2].step, 2)
    }

    func testSinkScopesPerTask() async {
        // Two concurrent tasks with different sinks must never cross-talk — the per-run
        // isolation the engine relies on (it binds one sink per run()).
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
            var items: [String] { lock.lock(); defer { lock.unlock() }; return storage }
        }
        let a = Box(), b = Box()
        async let runA: Void = RunProgress.$sink.withValue({ a.append($0.phase.rawValue) }) {
            await Task.yield()
            RunProgress.report(.denoise)
            RunProgress.report(.decode)
        }
        async let runB: Void = RunProgress.$sink.withValue({ b.append($0.phase.rawValue) }) {
            RunProgress.report(.encode)
            await Task.yield()
            RunProgress.report(.upsample)
        }
        _ = await (runA, runB)
        XCTAssertEqual(a.items, ["denoise", "decode"])
        XCTAssertEqual(b.items, ["encode", "upsample"])
    }

    func testPhaseVocabularyIsOpen() {
        // Governed like Mode/Specialty: unknown phases are legal; consumers render the raw value.
        let custom: RunPhase = "tile-upscale"
        XCTAssertEqual(custom.rawValue, "tile-upscale")
        XCTAssertNotEqual(custom, .upsample)
        XCTAssertEqual(RunPhase(rawValue: "denoise"), .denoise)
    }

    // MARK: - RunMonitor

    func testMonitorDefaultsToNilAndRecordsBothKeys() {
        let monitor = RunMonitor()
        XCTAssertNil(monitor.report(for: .textToVideo))

        let report = RunPhaseReport(phase: .denoise, step: 4, totalSteps: 8, stage: 2, totalStages: 2)
        monitor.update(.textToVideo, package: "ltx-2.3", to: report)
        // Observable by exact package…
        XCTAssertEqual(monitor.report(for: .textToVideo, package: "ltx-2.3"), report)
        // …and by capability alone (the engine writes both keys).
        XCTAssertEqual(monitor.report(for: .textToVideo), report)
        // Other capabilities untouched.
        XCTAssertNil(monitor.report(for: .tts))
    }

    func testMonitorClearRemovesBothKeys() {
        let monitor = RunMonitor()
        monitor.update(.textToVideo, package: "ltx-2.3", to: RunPhaseReport(phase: .decode))
        monitor.clear(.textToVideo, package: "ltx-2.3")
        XCTAssertNil(monitor.report(for: .textToVideo, package: "ltx-2.3"))
        XCTAssertNil(monitor.report(for: .textToVideo))
    }

    func testMonitorLatestReportWins() {
        let monitor = RunMonitor()
        monitor.update(.textToVideo, package: "ltx-2.3", to: RunPhaseReport(phase: .denoise, step: 1, totalSteps: 8))
        monitor.update(.textToVideo, package: "ltx-2.3", to: RunPhaseReport(phase: .denoise, step: 2, totalSteps: 8))
        XCTAssertEqual(monitor.report(for: .textToVideo)?.step, 2)
    }
}
