import XCTest
@testable import MLXServeConformance
import MLXToolKit

final class MLXServeConformanceTests: XCTestCase {
    // MLXServeConformance is a scaffolding placeholder this phase; this asserts the harness
    // target builds and tracks the current contract. Executable C0–C13 checks land with the
    // harness implementation.
    func testHarnessTracksCurrentContract() {
        XCTAssertEqual(MLXServeConformance.contractVersion, ContractVersion.current)
    }
}
