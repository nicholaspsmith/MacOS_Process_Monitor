import XCTest
@testable import ProcessMonitorCore

final class TopSpawnersTests: XCTestCase {
    func testCountsDescendantsAndExcludesPID1() {
        let procs = [
            ProcRec(pid: 1, ppid: 0, user: "root", etime: "", comm: "launchd"),
            ProcRec(pid: 10, ppid: 1, user: "nick", etime: "", comm: "parent"),
            ProcRec(pid: 11, ppid: 10, user: "nick", etime: "", comm: "child"),
            ProcRec(pid: 12, ppid: 11, user: "nick", etime: "", comm: "grandchild"),
        ]
        let top = topSpawners(procs, topN: 10)
        XCTAssertNil(top.first { $0.pid == 1 })            // PID 1 excluded
        let parent = top.first { $0.pid == 10 }
        XCTAssertEqual(parent?.descendants, 2)             // 11 + 12
    }
}
