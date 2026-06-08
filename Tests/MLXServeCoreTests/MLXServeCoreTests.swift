import XCTest
@testable import MLXServeCore
import MLXToolKit

final class MLXServeCoreTests: XCTestCase {
    // MLXServeCore is a scaffolding placeholder this phase; this asserts the target builds and
    // coordinates against the locked contract version. Real coordinator tests land with the
    // ToolRegistry / admission / requeue implementation.
    func testCoordinatesAgainstCurrentContract() {
        XCTAssertEqual(MLXServeCore.contractVersion, ContractVersion.current)
    }
}
