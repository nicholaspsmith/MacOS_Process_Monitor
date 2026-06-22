import Foundation

// MARK: - Respawn-loop detector

// Records per-comm PIDs at each poll, then flags names that look like a
// crash loop rather than a worker pool. Two patterns we need to tell apart:
//
//   crash loop:  peak simultaneous ≈ 1, but many distinct PIDs over time
//                (one slot keeps getting replaced — what contactsd did
//                during the May 19 incident).
//
//   worker pool: peak simultaneous = N, many distinct PIDs over time
//                (mdworker_shared, plugin-container, ExtensionKit
//                helpers — all designed to be short-lived).
//
// The discriminator is `distinct / peak`: how many times each slot was
// replaced inside the window. Flag only when that ratio is high enough
// that normal short-lived helpers don't trip it.
//
// Also excluded: `ps` (we spawn it every poll, so it'd always self-flag)
// and `<defunct>` (a state, not an identity — every reaped zombie ends
// up there regardless of original name).
public final class RespawnDetector {
    private var snapshots: [[String: Set<Int>]] = []
    private let windowSize: Int
    private let minDistinct: Int
    private let minChurnRatio: Int

    private static let excluded: Set<String> = ["ps", "<defunct>"]

    public init(windowSize: Int, minDistinct: Int, minChurnRatio: Int) {
        self.windowSize = windowSize
        self.minDistinct = minDistinct
        self.minChurnRatio = minChurnRatio
    }

    public func record(_ procs: [ProcRec]) {
        var byComm: [String: Set<Int>] = [:]
        for p in procs {
            byComm[p.comm, default: []].insert(p.pid)
        }
        snapshots.append(byComm)
        if snapshots.count > windowSize { snapshots.removeFirst() }
    }

    public struct Looping {
        public let comm: String
        public let distinct: Int
        public let peak: Int

        public init(comm: String, distinct: Int, peak: Int) {
            self.comm = comm
            self.distinct = distinct
            self.peak = peak
        }
    }

    public func looping() -> [Looping] {
        var union: [String: Set<Int>] = [:]
        var peak: [String: Int] = [:]
        for snap in snapshots {
            for (c, pids) in snap {
                union[c, default: []].formUnion(pids)
                peak[c] = max(peak[c] ?? 0, pids.count)
            }
        }
        return union.compactMap { (c, pids) -> Looping? in
            let basename = (c as NSString).lastPathComponent
            if Self.excluded.contains(basename) { return nil }
            let distinct = pids.count
            let p = max(peak[c] ?? 1, 1)
            guard distinct > minDistinct, distinct / p >= minChurnRatio else { return nil }
            return Looping(comm: c, distinct: distinct, peak: p)
        }
        .sorted { $0.distinct > $1.distinct }
    }
}
