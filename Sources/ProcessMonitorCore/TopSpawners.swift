import Foundation

// MARK: - Top spawners

// Counts each PID's total descendants (transitive children) by walking the
// PPID graph. Returns the top N PIDs that actually have descendants, sorted
// descending. PID 1 (launchd) is excluded — it's the ancestor of nearly
// every userland process, so it would always pin to the top with no signal.
public func topSpawners(_ all: [ProcRec], topN: Int) -> [(comm: String, pid: Int, descendants: Int)] {
    var children: [Int: [Int]] = [:]
    for p in all {
        children[p.ppid, default: []].append(p.pid)
    }
    var counts: [Int: Int] = [:]
    for p in all where p.pid != 1 {
        var n = 0
        var stack = children[p.pid] ?? []
        while let pid = stack.popLast() {
            n += 1
            if let cs = children[pid] { stack.append(contentsOf: cs) }
        }
        if n > 0 { counts[p.pid] = n }
    }
    return all
        .compactMap { p -> (comm: String, pid: Int, descendants: Int)? in
            guard let n = counts[p.pid] else { return nil }
            return (displayName(p.comm), p.pid, n)
        }
        .sorted { $0.descendants > $1.descendants }
        .prefix(topN)
        .map { $0 }
}
