import Foundation

// MARK: - Process snapshot

/// One row from `ps -axo pid,ppid,user,etime,comm`.
public struct ProcRec: Equatable {
    public let pid: Int
    public let ppid: Int
    public let user: String
    public let etime: String  // elapsed time since start, e.g. "01:23" or "1-02:34:56"
    public let comm: String   // executable basename; can include spaces (e.g. "Google Chrome Helper")

    public init(pid: Int, ppid: Int, user: String, etime: String, comm: String) {
        self.pid = pid
        self.ppid = ppid
        self.user = user
        self.etime = etime
        self.comm = comm
    }
}

/// Parse the text output of `ps -axo pid,ppid,user,etime,comm -ww`. Drops the
/// header line; for each remaining line the first 4 whitespace-separated tokens
/// are pid/ppid/user/etime and everything after is comm (which may contain
/// spaces). Lines that don't yield 5 tokens with integer pid/ppid are skipped.
public func parseProcs(_ psOutput: String) -> [ProcRec] {
    var result: [ProcRec] = []
    let lines = psOutput.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // First 4 tokens are pid/ppid/user/etime; everything after is comm (may contain spaces).
        let parts = trimmed.split(
            maxSplits: 4,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        ).map(String.init)
        guard parts.count == 5,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]) else { continue }
        result.append(ProcRec(pid: pid, ppid: ppid, user: parts[2], etime: parts[3], comm: parts[4]))
    }
    return result
}

// Strip the absolute path prefix that `ps -axo comm` returns for most
// processes (e.g. "/sbin/launchd" → "launchd"), and drop the leading "-"
// that ps prepends to login shells ("-zsh" → "zsh").
public func displayName(_ comm: String) -> String {
    var s = comm
    if s.hasPrefix("-") { s = String(s.dropFirst()) }
    return (s as NSString).lastPathComponent
}
