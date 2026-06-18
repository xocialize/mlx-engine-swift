import XCTest
@testable import MLXToolKit

@MainActor
final class PreparationMonitorTests: XCTestCase {
    func testDefaultsToIdleAndRecordsPhases() {
        let monitor = PreparationMonitor()
        XCTAssertEqual(monitor.phase(for: .imageRestore), .idle)

        monitor.update(.imageRestore, package: "nafnet", to: .downloading(fraction: 0.5, bytesPerSecond: 8_000_000))
        // Observable by exact package…
        XCTAssertEqual(monitor.phase(for: .imageRestore, package: "nafnet"),
                       .downloading(fraction: 0.5, bytesPerSecond: 8_000_000))
        // …and by capability alone (the engine writes both keys).
        XCTAssertEqual(monitor.phase(for: .imageRestore),
                       .downloading(fraction: 0.5, bytesPerSecond: 8_000_000))

        monitor.update(.imageRestore, package: "nafnet", to: .ready)
        XCTAssertEqual(monitor.phase(for: .imageRestore), .ready)
    }

    func testReportForwardsToBoundSink() {
        final class Box: @unchecked Sendable { var items: [(Double, Double?)] = [] }
        let box = Box()
        let sink: WeightDownloadProgress.Sink = { f, bps in box.items.append((f, bps)) }
        WeightDownloadProgress.$sink.withValue(sink) {
            WeightDownloadProgress.report(fraction: 0.25, bytesPerSecond: 1_000)
            WeightDownloadProgress.report(fraction: 0.75, bytesPerSecond: nil)
        }
        // Unbound → no-op (must not crash).
        WeightDownloadProgress.report(fraction: 1.0)
        XCTAssertEqual(box.items.count, 2)
        XCTAssertEqual(box.items[0].0, 0.25)
        XCTAssertEqual(box.items[1].0, 0.75)
    }
}
