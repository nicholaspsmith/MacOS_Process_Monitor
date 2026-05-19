import AppKit
import UserNotifications

// MARK: - Kernel limit

func readProcessLimit() -> Int {
    var size = 0
    sysctlbyname("kern.maxprocperuid", nil, &size, nil, 0)
    var value: Int32 = 0
    let result = sysctlbyname("kern.maxprocperuid", &value, &size, nil, 0)
    return result == 0 && value > 0 ? Int(value) : 2666
}

// MARK: - Process snapshot

struct ProcRec {
    let pid: Int
    let ppid: Int
    let user: String
    let comm: String  // executable basename; can include spaces (e.g. "Google Chrome Helper")
}

func readAllProcs() -> [ProcRec]? {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-axo", "pid,ppid,user,comm", "-ww"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8) else { return nil }

    var result: [ProcRec] = []
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(
            maxSplits: 3,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        ).map(String.init)
        guard parts.count == 4,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]) else { continue }
        result.append(ProcRec(pid: pid, ppid: ppid, user: parts[2], comm: parts[3]))
    }
    return result
}

// MARK: - Top spawners

// Strip the absolute path prefix that `ps -axo comm` returns for most
// processes (e.g. "/sbin/launchd" → "launchd"), and drop the leading "-"
// that ps prepends to login shells ("-zsh" → "zsh").
func displayName(_ comm: String) -> String {
    var s = comm
    if s.hasPrefix("-") { s = String(s.dropFirst()) }
    return (s as NSString).lastPathComponent
}

// Counts each PID's total descendants (transitive children) by walking the
// PPID graph. Returns the top N PIDs that actually have descendants, sorted
// descending. PID 1 (launchd) is excluded — it's the ancestor of nearly
// every userland process, so it would always pin to the top with no signal.
func topSpawners(_ all: [ProcRec], topN: Int) -> [(comm: String, pid: Int, descendants: Int)] {
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

// MARK: - Sparkline history

final class CountHistory {
    private var values: [Int] = []
    private let maxLen: Int
    init(maxLen: Int) { self.maxLen = maxLen }

    func record(_ v: Int) {
        values.append(v)
        if values.count > maxLen { values.removeFirst() }
    }

    func sparkline() -> String {
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        guard !values.isEmpty else { return "" }
        let lo = values.min()!
        let hi = values.max()!
        guard hi > lo else {
            return String(repeating: bars[3], count: values.count)
        }
        let span = Double(hi - lo)
        return values.map { v in
            let frac = Double(v - lo) / span
            let idx = min(bars.count - 1, Int(frac * Double(bars.count)))
            return bars[idx]
        }.joined()
    }

    var range: (min: Int, max: Int)? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return (lo, hi)
    }
}

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
final class RespawnDetector {
    private var snapshots: [[String: Set<Int>]] = []
    private let windowSize: Int
    private let minDistinct: Int
    private let minChurnRatio: Int

    private static let excluded: Set<String> = ["ps", "<defunct>"]

    init(windowSize: Int, minDistinct: Int, minChurnRatio: Int) {
        self.windowSize = windowSize
        self.minDistinct = minDistinct
        self.minChurnRatio = minChurnRatio
    }

    func record(_ procs: [ProcRec]) {
        var byComm: [String: Set<Int>] = [:]
        for p in procs {
            byComm[p.comm, default: []].insert(p.pid)
        }
        snapshots.append(byComm)
        if snapshots.count > windowSize { snapshots.removeFirst() }
    }

    struct Looping {
        let comm: String
        let distinct: Int
        let peak: Int
    }

    func looping() -> [Looping] {
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let limit = readProcessLimit()
    private let warnPct = 85
    private let pollSeconds: TimeInterval = 5
    private let historyLen = 40                    // ~3.3 min of sparkline at 5s polls
    private let respawnWindow = 12                 // 60s window at 5s polls
    private let respawnMinDistinct = 5             // need at least this many PIDs over the window
    private let respawnMinChurnRatio = 5           // and distinct/peak >= this (slot replaced N times)

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var lastNotifiedAtOrAbove = false
    private let history: CountHistory
    private let respawn: RespawnDetector
    private var latestProcs: [ProcRec] = []
    private var latestCount = 0

    override init() {
        history = CountHistory(maxLen: historyLen)
        respawn = RespawnDetector(
            windowSize: respawnWindow,
            minDistinct: respawnMinDistinct,
            minChurnRatio: respawnMinChurnRatio
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.attributedTitle = NSAttributedString(string: "…")

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Menu (lazy rebuild on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Sparkline (informational)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let spark = history.sparkline()
        let sparkText: String = {
            if let r = history.range, r.max > r.min {
                return "History  \(spark)   \(r.min)→\(r.max)"
            }
            return "History  \(spark)"
        }()
        let sparkItem = NSMenuItem(title: sparkText, action: nil, keyEquivalent: "")
        sparkItem.attributedTitle = NSAttributedString(
            string: sparkText,
            attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]
        )
        menu.addItem(sparkItem)

        // Crash-loop section (only when present)
        let loops = respawn.looping()
        if !loops.isEmpty {
            let header = NSMenuItem(title: "⚠ Crash-looping (\(loops.count))", action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(
                string: "⚠ Crash-looping (\(loops.count))",
                attributes: [.foregroundColor: NSColor.systemRed]
            )
            let sub = NSMenu()
            for l in loops.prefix(10) {
                let windowSec = respawnWindow * Int(pollSeconds)
                let line = "\(displayName(l.comm))  —  \(l.distinct) PIDs / peak \(l.peak) live  (in \(windowSec)s)"
                sub.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            }
            header.submenu = sub
            menu.addItem(header)
        }

        // Top spawners
        let spawners = topSpawners(latestProcs, topN: 10)
        let spawnHeader = NSMenuItem(title: "Top spawners", action: nil, keyEquivalent: "")
        let spawnSub = NSMenu()
        if spawners.isEmpty {
            spawnSub.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: ""))
        } else {
            for s in spawners {
                let line = "\(s.comm) [\(s.pid)]  —  \(s.descendants) desc"
                spawnSub.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            }
        }
        spawnHeader.submenu = spawnSub
        menu.addItem(spawnHeader)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "a"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    // MARK: Polling

    private func refresh() {
        guard let all = readAllProcs() else {
            statusItem.button?.attributedTitle = NSAttributedString(string: "ps?")
            return
        }
        latestProcs = all
        let user = NSUserName()
        let count = all.reduce(0) { $0 + ($1.user == user ? 1 : 0) }
        latestCount = count
        history.record(count)
        respawn.record(all)

        let pct = count * 100 / limit
        let color: NSColor = pct >= warnPct ? .systemRed : .labelColor
        statusItem.button?.attributedTitle = NSAttributedString(
            string: "\(count)/\(limit) (\(pct)%)",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            ]
        )

        if pct >= warnPct {
            if !lastNotifiedAtOrAbove {
                notify(count: count, pct: pct)
                lastNotifiedAtOrAbove = true
            }
        } else if pct < warnPct - 5 {
            lastNotifiedAtOrAbove = false
        }
    }

    private func notify(count: Int, pct: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Process count high"
        content.body = "\(count) of \(limit) processes (\(pct)%). Kill some before fork() starts failing."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "process-monitor.threshold.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
