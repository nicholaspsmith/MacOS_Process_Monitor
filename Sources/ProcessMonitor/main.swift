import AppKit
// Re-exported so ProcRec / displayName / etc. are visible module-wide,
// including to ProcessDetailWindow.swift (which is intentionally left
// unmodified and has no import of its own).
@_exported import ProcessMonitorCore
import StatusItemKit

// MARK: - Kernel limit

func readProcessLimit() -> Int {
    var size = 0
    sysctlbyname("kern.maxprocperuid", nil, &size, nil, 0)
    var value: Int32 = 0
    let result = sysctlbyname("kern.maxprocperuid", &value, &size, nil, 0)
    return result == 0 && value > 0 ? Int(value) : 2666
}

// MARK: - Process snapshot

// Runs `ps` and parses it into [ProcRec]. Thin wrapper over StatusItemKit's
// Shell + ProcessMonitorCore's parseProcs; kept in the app target because
// ProcessDetailWindow.swift (which re-runs ps on its own timer) calls it.
func readAllProcs() -> [ProcRec]? {
    guard let text = Shell.run("/bin/ps", ["-axo", "pid,ppid,user,etime,comm", "-ww"]) else { return nil }
    return parseProcs(text)
}

// MARK: - Settings

/// How the menu bar status item is rendered. Persisted in UserDefaults.
enum DisplayMode: String {
    case countTotalPct   // "1234/2666 (46%)"  — default
    case countTotal      // "1234/2666"
    case percent         // "46%"
    case gauge           // custom-drawn speedometer (needle) reflecting pct
    case arc             // custom-drawn radial arc filled proportionally to pct
    case pie             // custom-drawn pie: filled wedge = in use, circle outline = cap
    case wedge           // custom-drawn pie: solid wedge = in use, faint disk = remaining cap

    private static let storageKey = "displayMode"
    static var current: DisplayMode {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(DisplayMode.init) ?? .countTotalPct }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let limit = readProcessLimit()
    private let warnPct = 85
    private let pollSeconds: TimeInterval = 5
    private let historyLen = 25                    // ~2 min of sparkline at 5s polls (narrower menu)
    private let respawnWindow = 12                 // 60s window at 5s polls
    private let respawnMinDistinct = 5             // need at least this many PIDs over the window
    private let respawnMinChurnRatio = 5           // and distinct/peak >= this (slot replaced N times)

    private var controller: StatusItemController!
    private let notifier = Notifier()
    private var lastNotifiedAtOrAbove = false
    private let history: CountHistory
    private let respawn: RespawnDetector
    private var latestProcs: [ProcRec] = []
    private var latestCount = 0
    private var detailWindows: [ProcessDetailWindowController] = []
    private let pollQueue = DispatchQueue(label: "processmonitor.poll")
    private var pollInFlight = false   // main-thread only; drops overlapping polls

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
        notifier.requestAuthorization()

        controller = StatusItemController(
            pollInterval: pollSeconds,
            onPoll: { [weak self] in self?.refresh() },
            onBuildMenu: { [weak self] menu in self?.buildMenu(menu) }
        )
        controller.start()
    }

    // MARK: Menu (lazy rebuild on open)

    private func buildMenu(_ menu: NSMenu) {
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
        sparkItem.view = MenuBuilder.textView(sparkText, font: mono)
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
            (.gauge, "Gauge (needle)"),
            (.arc, "Gauge (arc)"),
            (.pie, "Pie (outline)"),
            (.wedge, "Pie (filled)"),
        ]
        let activeMode = DisplayMode.current
        for (mode, label) in modes {
            let item = NSMenuItem(title: label, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == activeMode) ? .on : .off
            displaySub.addItem(item)
        }
        displayHeader.submenu = displaySub
        menu.addItem(displayHeader)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "a"))

        // Start at Login toggle. Reflects current SMAppService status.
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        LoginItem.toggle()
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

    private func rerenderFromCache() {
        let pct = limit > 0 ? latestCount * 100 / limit : 0
        renderStatusItem(count: latestCount, limit: limit, pct: pct, warn: pct >= warnPct)
    }

    // MARK: Polling

    // Invoked on the main thread by StatusItemController's timer. The blocking
    // `ps` call (readAllProcs → Shell.run) runs on a background queue so it can
    // never freeze the run loop and stop the status-item menu opening on click;
    // state (latestProcs/latestCount/history/respawn) is mutated back on main,
    // so buildMenu reads only main-written state and there's no data race.
    // Overlapping ticks are dropped. (ProcessDetailWindow keeps its own on-main
    // ps refresh — now timeout-bounded by Shell.run — and is left unchanged.)
    private func refresh() {
        if pollInFlight { return }
        pollInFlight = true
        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let procs = readAllProcs()   // Shell.run("/bin/ps") + parseProcs, off main
            DispatchQueue.main.async {
                self.pollInFlight = false
                guard let all = procs else {
                    self.controller.button?.attributedTitle = NSAttributedString(string: "ps?")
                    return
                }
                self.latestProcs = all
                let user = NSUserName()
                let count = all.reduce(0) { $0 + ($1.user == user ? 1 : 0) }
                self.latestCount = count
                self.history.record(count)
                self.respawn.record(all)

                let pct = count * 100 / self.limit
                self.renderStatusItem(count: count, limit: self.limit, pct: pct, warn: pct >= self.warnPct)

                if pct >= self.warnPct {
                    if !self.lastNotifiedAtOrAbove {
                        self.notify(count: count, pct: pct)
                        self.lastNotifiedAtOrAbove = true
                    }
                } else if pct < self.warnPct - 5 {
                    self.lastNotifiedAtOrAbove = false
                }
            }
        }
    }

    // Single render funnel. Text modes and icon modes are mutually exclusive:
    // text via controller.setTitle (red on warn), icons via controller.setIcon.
    // Icon color encodes severity (green <50%, orange <warnPct, red ≥ warnPct).
    private func renderStatusItem(count: Int, limit: Int, pct: Int, warn: Bool) {
        let mode = DisplayMode.current
        let frac = CGFloat(max(0, min(100, pct))) / 100
        let color = Severity.level(pct: pct, warnPct: warnPct).color

        switch mode {
        case .countTotalPct:
            controller.setTitle("\(count)/\(limit) (\(pct)%)", warn: warn)
        case .countTotal:
            controller.setTitle("\(count)/\(limit)", warn: warn)
        case .percent:
            controller.setTitle("\(pct)%", warn: warn)
        case .gauge:
            controller.setIcon(MeterIcon.gauge(fraction: frac, color: color))
        case .arc:
            controller.setIcon(MeterIcon.arc(fraction: frac, color: color))
        case .pie:
            controller.setIcon(MeterIcon.pie(fraction: frac, color: color))
        case .wedge:
            controller.setIcon(MeterIcon.wedge(fraction: frac, color: color))
        }
    }

    private func notify(count: Int, pct: Int) {
        notifier.post(
            title: "Process count high",
            body: "\(count) of \(limit) processes (\(pct)%). Kill some before fork() starts failing."
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
