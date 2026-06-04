import AppKit
import ServiceManagement
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
    let etime: String  // elapsed time since start, e.g. "01:23" or "1-02:34:56"
    let comm: String   // executable basename; can include spaces (e.g. "Google Chrome Helper")
}

func readAllProcs() -> [ProcRec]? {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-axo", "pid,ppid,user,etime,comm", "-ww"]
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

// MARK: - Settings

enum DisplayMode: String {
    case countTotalPct   // "1234/2666 (46%)"  — default
    case countTotal      // "1234/2666"
    case percent         // "46%"
    case iconOnly        // SF Symbol or bare number, per IconStyle

    private static let storageKey = "displayMode"
    static var current: DisplayMode {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(DisplayMode.init) ?? .countTotalPct }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

enum IconStyle: String {
    case gauge           // gauge SF Symbol — default
    case chart           // chart.bar SF Symbol
    case number          // bare percent number, no "%"

    private static let storageKey = "iconStyle"
    static var current: IconStyle {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(IconStyle.init) ?? .gauge }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let limit = readProcessLimit()
    private let warnPct = 85
    private let pollSeconds: TimeInterval = 5
    private let historyLen = 25                    // ~2 min of sparkline at 5s polls (narrower menu)
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
    private var detailWindows: [ProcessDetailWindowController] = []

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

        // Sparkline — view-based so it doesn't reserve trailing space for the
        // keyboard-shortcut column that macOS menus apply to standard items.
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let spark = history.sparkline()
        let sparkText: String = {
            if let r = history.range, r.max > r.min {
                return "\(spark)   \(r.min)→\(r.max)"
            }
            return spark
        }()
        let sparkItem = NSMenuItem()
        sparkItem.view = makeSparklineView(text: sparkText, font: mono)
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

        // Top spawners — clickable; opens a detail window with kill actions.
        let spawners = topSpawners(latestProcs, topN: 10)
        let spawnHeader = NSMenuItem(title: "Top spawners", action: nil, keyEquivalent: "")
        let spawnSub = NSMenu()
        if spawners.isEmpty {
            spawnSub.addItem(NSMenuItem(title: "(none)", action: nil, keyEquivalent: ""))
        } else {
            for s in spawners {
                let line = "\(s.comm) [\(s.pid)]  —  \(s.descendants) desc"
                let item = NSMenuItem(title: line, action: #selector(showSpawnerDetail(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: s.pid)
                spawnSub.addItem(item)
            }
        }
        spawnHeader.submenu = spawnSub
        menu.addItem(spawnHeader)

        // Display mode submenu (mirrors the Start at Login pattern: read current
        // setting for checkmark state; action writes it and re-renders).
        menu.addItem(NSMenuItem.separator())
        let displayHeader = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displaySub = NSMenu()
        let modes: [(DisplayMode, String)] = [
            (.countTotalPct, "Count / Total (%)"),
            (.countTotal, "Count / Total"),
            (.percent, "Percent"),
            (.iconOnly, "Icon only"),
        ]
        let activeMode = DisplayMode.current
        for (mode, label) in modes {
            let item = NSMenuItem(title: label, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == activeMode) ? .on : .off
            displaySub.addItem(item)
        }
        if activeMode == .iconOnly {
            displaySub.addItem(NSMenuItem.separator())
            let iconHeader = NSMenuItem(title: "Icon style", action: nil, keyEquivalent: "")
            let iconSub = NSMenu()
            let styles: [(IconStyle, String)] = [
                (.gauge, "Gauge"),
                (.chart, "Chart"),
                (.number, "Number"),
            ]
            let activeStyle = IconStyle.current
            for (style, label) in styles {
                let item = NSMenuItem(title: label, action: #selector(setIconStyle(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = style.rawValue
                item.state = (style == activeStyle) ? .on : .off
                iconSub.addItem(item)
            }
            iconHeader.submenu = iconSub
            displaySub.addItem(iconHeader)
        }
        displayHeader.submenu = displaySub
        menu.addItem(displayHeader)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "a"))

        // Start at Login toggle. Reflects current SMAppService status.
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Wraps a label in an NSView sized to its intrinsic content. Used so the
    // sparkline item escapes NSMenu's standard layout (where every row
    // reserves columns for checkmark + shortcut indicator alignment).
    // Uses explicit frames rather than constraints — NSMenu reads the view's
    // frame at insertion time, before any auto-layout pass would have run, so
    // a constraint-only view ends up zero-sized and invisible. Measures text
    // directly via NSString.size(withAttributes:) since NSTextField's
    // intrinsicContentSize rounds down to sub-pixel values and clips the
    // trailing glyph.
    private func makeSparklineView(text: String, font: NSFont) -> NSView {
        let leftPad: CGFloat = 20
        let rightPad: CGFloat = 6
        let vPad: CGFloat = 3
        // Safety buffer: covers sub-pixel font metrics so the last glyph
        // never clips, regardless of which characters end up in the text.
        let textBuffer: CGFloat = 4

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attrs)
        let labelWidth = ceil(measured.width) + textBuffer
        let labelHeight = ceil(measured.height)

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: leftPad, y: vPad, width: labelWidth, height: labelHeight)

        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: labelWidth + leftPad + rightPad,
            height: labelHeight + vPad * 2
        ))
        container.addSubview(label)
        return container
    }

    @objc private func showSpawnerDetail(_ sender: NSMenuItem) {
        guard let pid = (sender.representedObject as? NSNumber)?.intValue else { return }
        let controller = ProcessDetailWindowController(pid: pid) { [weak self] closed in
            self?.detailWindows.removeAll { $0 === closed }
        }
        detailWindows.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            // Most common failure: app isn't in /Applications or ~/Applications.
            let alert = NSAlert()
            alert.messageText = "Couldn't toggle Start at Login"
            alert.informativeText = """
            \(error.localizedDescription)

            macOS requires the app to live in /Applications or ~/Applications for this to work. Move ProcessMonitor.app there and try again.
            """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        DisplayMode.current = mode
        rerenderFromCache()
    }

    @objc private func setIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = IconStyle(rawValue: raw) else { return }
        IconStyle.current = style
        rerenderFromCache()
    }

    private func rerenderFromCache() {
        let pct = limit > 0 ? latestCount * 100 / limit : 0
        renderStatusItem(count: latestCount, limit: limit, pct: pct, warn: pct >= warnPct)
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
        renderStatusItem(count: count, limit: limit, pct: pct, warn: pct >= warnPct)

        if pct >= warnPct {
            if !lastNotifiedAtOrAbove {
                notify(count: count, pct: pct)
                lastNotifiedAtOrAbove = true
            }
        } else if pct < warnPct - 5 {
            lastNotifiedAtOrAbove = false
        }
    }

    private func renderStatusItem(count: Int, limit: Int, pct: Int, warn: Bool) {
        guard let button = statusItem.button else { return }
        let mode = DisplayMode.current

        // Helper to render text and clear any image.
        func renderText(_ s: String) {
            button.image = nil
            button.imagePosition = .noImage
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(
                string: s,
                attributes: [
                    .foregroundColor: warn ? NSColor.systemRed : NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                ]
            )
        }

        switch mode {
        case .countTotalPct:
            renderText("\(count)/\(limit) (\(pct)%)")
        case .countTotal:
            renderText("\(count)/\(limit)")
        case .percent:
            renderText("\(pct)%")
        case .iconOnly:
            switch IconStyle.current {
            case .number:
                renderText("\(pct)")          // bare number, no "%"
            case .gauge:
                renderSymbol(warn ? "gauge.with.dots.needle.100percent" : "gauge.with.dots.needle.50percent", warn: warn)
            case .chart:
                renderSymbol(warn ? "chart.bar.fill" : "chart.bar", warn: warn)
            }
        }
    }

    private func renderSymbol(_ name: String, warn: Bool) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Process usage")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = warn ? .systemRed : nil
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
