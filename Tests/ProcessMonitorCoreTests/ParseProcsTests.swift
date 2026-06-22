import XCTest
@testable import ProcessMonitorCore

final class ParseProcsTests: XCTestCase {
    func testParsesRowsAndCommWithSpaces() {
        let out = """
        PID  PPID USER     ELAPSED COMM
          1     0 root     10-00:00:00 /sbin/launchd
        500     1 nick     01:23 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper
        """
        let procs = parseProcs(out)
        XCTAssertEqual(procs.count, 2)
        XCTAssertEqual(procs[0], ProcRec(pid: 1, ppid: 0, user: "root", etime: "10-00:00:00", comm: "/sbin/launchd"))
        XCTAssertEqual(procs[1].comm, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper")
    }
    func testSkipsMalformedLines() {
        XCTAssertTrue(parseProcs("PID PPID USER ELAPSED COMM\ngarbage").isEmpty)
    }
    func testDisplayName() {
        XCTAssertEqual(displayName("/sbin/launchd"), "launchd")
        XCTAssertEqual(displayName("-zsh"), "zsh")
        XCTAssertEqual(displayName("Google Chrome Helper"), "Google Chrome Helper")
    }
}
