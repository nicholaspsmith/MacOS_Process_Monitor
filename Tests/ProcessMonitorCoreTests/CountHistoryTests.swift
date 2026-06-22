import XCTest
@testable import ProcessMonitorCore

final class CountHistoryTests: XCTestCase {
    func testSparklineLengthAndRange() {
        let h = CountHistory(maxLen: 25)
        [10, 20, 30].forEach { h.record($0) }
        XCTAssertEqual(h.sparkline().count, 3)
        XCTAssertEqual(h.range?.min, 10)
        XCTAssertEqual(h.range?.max, 30)
    }
    func testTrimsToMaxLen() {
        let h = CountHistory(maxLen: 2)
        [1, 2, 3].forEach { h.record($0) }
        XCTAssertEqual(h.range?.min, 2)   // first dropped
    }
}
