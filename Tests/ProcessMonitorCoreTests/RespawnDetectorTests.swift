import XCTest
@testable import ProcessMonitorCore

final class RespawnDetectorTests: XCTestCase {
    private func rec(_ pid: Int, _ comm: String) -> ProcRec { ProcRec(pid: pid, ppid: 1, user: "nick", etime: "", comm: comm) }

    func testFlagsCrashLoopOneSlotManyPids() {
        let d = RespawnDetector(windowSize: 12, minDistinct: 5, minChurnRatio: 5)
        // one live at a time, replaced each poll -> peak 1, distinct large
        for pid in 100..<112 { d.record([rec(pid, "crasher")]) }
        XCTAssertTrue(d.looping().contains { $0.comm == "crasher" })
    }
    func testDoesNotFlagWorkerPool() {
        let d = RespawnDetector(windowSize: 12, minDistinct: 5, minChurnRatio: 5)
        // many live simultaneously, modest turnover -> high peak, low ratio.
        // 8 stable slots; one slot rotates each poll. distinct ≈ 8 + (window-1),
        // peak = 8, so distinct/peak stays well below the churn-ratio gate of 5.
        for i in 0..<12 {
            var pids = (0..<7).map { $0 * 100 }   // 7 stable slots: 0,100,...,600
            pids.append(700 + i)                   // 8th slot rotates each poll
            d.record(pids.map { rec(1000 + $0, "mdworker_shared") })
        }
        XCTAssertFalse(d.looping().contains { $0.comm == "mdworker_shared" })
    }
    func testExcludesPsAndDefunct() {
        let d = RespawnDetector(windowSize: 12, minDistinct: 5, minChurnRatio: 5)
        for pid in 200..<212 { d.record([rec(pid, "/bin/ps"), rec(pid + 1000, "<defunct>")]) }
        XCTAssertTrue(d.looping().isEmpty)
    }
}
