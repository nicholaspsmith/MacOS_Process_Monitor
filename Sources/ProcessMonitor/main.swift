import AppKit
import UserNotifications

// macOS per-UID process limit lives in kern.maxprocperuid. We read it once at
// launch; if anything goes wrong we fall back to 2666 (the typical default).
func readProcessLimit() -> Int {
    var size = 0
    sysctlbyname("kern.maxprocperuid", nil, &size, nil, 0)
    var value: Int32 = 0
    let result = sysctlbyname("kern.maxprocperuid", &value, &size, nil, 0)
    return result == 0 && value > 0 ? Int(value) : 2666
}

// Counts processes owned by the current user. Mirrors `ps -u $USER | wc -l`
// (minus the header row). Uses /bin/ps so behavior matches what users see in
// their own shell — no clever sysctl arithmetic that could drift.
func currentProcessCount() -> Int? {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-u", NSUserName()]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8) else {
        return nil
    }
    // ps prints a header line; subtract it.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    return max(lines.count - 1, 0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let limit = readProcessLimit()
    private let warnPct = 85
    private let pollSeconds: TimeInterval = 5

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastNotifiedAtOrAbove = false  // edge-trigger; renotify only on re-cross

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = "…"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        guard let count = currentProcessCount() else {
            statusItem.button?.title = "ps?"
            return
        }
        let pct = count * 100 / limit
        statusItem.button?.title = "\(count)/\(limit) (\(pct)%)"

        if pct >= warnPct {
            if !lastNotifiedAtOrAbove {
                notify(count: count, pct: pct)
                lastNotifiedAtOrAbove = true
            }
        } else if pct < warnPct - 5 {
            // 5pt hysteresis so a single bounce around the threshold doesn't spam.
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
app.setActivationPolicy(.accessory)  // no Dock icon
app.run()
