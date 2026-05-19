import AppKit
import Foundation

// Window that opens when you click a Top Spawners entry. Re-runs ps every 2s
// while open so the descendant list and elapsed times stay live; closes itself
// once it can't find the target PID anymore (the process exited).
final class ProcessDetailWindowController: NSWindowController, NSWindowDelegate {
    private let pid: Int
    private let onClose: (ProcessDetailWindowController) -> Void
    private var refreshTimer: Timer?
    private let refreshSeconds: TimeInterval = 2

    // UI
    private let summaryField = NSTextField(labelWithString: "")
    private let childrenView = NSTextView()
    private let scrollView = NSScrollView()
    private let quitButton = NSButton(title: "Quit (SIGTERM)", target: nil, action: nil)
    private let forceQuitButton = NSButton(title: "Force Quit (SIGKILL)", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let statusField = NSTextField(labelWithString: "")

    init(pid: Int, onClose: @escaping (ProcessDetailWindowController) -> Void) {
        self.pid = pid
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Process \(pid)"
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        buildLayout()
        wireActions()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Layout

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        summaryField.font = NSFont.systemFont(ofSize: 13)
        summaryField.lineBreakMode = .byWordWrapping
        summaryField.maximumNumberOfLines = 0
        summaryField.translatesAutoresizingMaskIntoConstraints = false

        let childrenHeader = NSTextField(labelWithString: "Descendants")
        childrenHeader.font = NSFont.boldSystemFont(ofSize: 12)
        childrenHeader.translatesAutoresizingMaskIntoConstraints = false

        childrenView.isEditable = false
        childrenView.isRichText = false
        childrenView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        childrenView.backgroundColor = .textBackgroundColor

        scrollView.documentView = childrenView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        quitButton.bezelStyle = .rounded
        forceQuitButton.bezelStyle = .rounded
        refreshButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [quitButton, forceQuitButton, refreshButton, NSView(), closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        statusField.font = NSFont.systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(summaryField)
        contentView.addSubview(childrenHeader)
        contentView.addSubview(scrollView)
        contentView.addSubview(buttonRow)
        contentView.addSubview(statusField)

        NSLayoutConstraint.activate([
            summaryField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            summaryField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            childrenHeader.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 14),
            childrenHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: childrenHeader.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -8),

            statusField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    private func wireActions() {
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        forceQuitButton.target = self
        forceQuitButton.action = #selector(forceQuitClicked)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
    }

    // MARK: - Refresh

    @objc private func refreshClicked() {
        refresh()
    }

    private func refresh() {
        guard let all = readAllProcs() else {
            statusField.stringValue = "ps failed"
            return
        }
        guard let target = all.first(where: { $0.pid == pid }) else {
            // Process is gone — close out.
            statusField.stringValue = "Process \(pid) is no longer running."
            quitButton.isEnabled = false
            forceQuitButton.isEnabled = false
            return
        }
        let parent = all.first(where: { $0.pid == target.ppid })
        let parentLabel = parent.map { "\(displayName($0.comm)) [\($0.pid)]" } ?? "(pid \(target.ppid))"

        summaryField.stringValue = """
        \(displayName(target.comm))   [\(target.pid)]
        User: \(target.user)
        Parent: \(parentLabel)
        Elapsed: \(target.etime)
        """

        // All transitive descendants, sorted by elapsed (longest-lived first).
        var children: [Int: [Int]] = [:]
        for p in all { children[p.ppid, default: []].append(p.pid) }
        var descendants: [ProcRec] = []
        var stack = children[target.pid] ?? []
        let byPid = Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0) })
        while let nextPid = stack.popLast() {
            if let rec = byPid[nextPid] {
                descendants.append(rec)
                if let cs = children[nextPid] { stack.append(contentsOf: cs) }
            }
        }

        func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
        var rows = pad("PID", 7) + "  " + pad("NAME", 30) + "  ETIME\n"
        rows += String(repeating: "─", count: 60) + "\n"
        if descendants.isEmpty {
            rows += "(none)\n"
        } else {
            for d in descendants.sorted(by: { $0.pid < $1.pid }) {
                let name = displayName(d.comm)
                let truncated = name.count > 30 ? String(name.prefix(29)) + "…" : name
                rows += pad("\(d.pid)", 7) + "  " + pad(truncated, 30) + "  " + d.etime + "\n"
            }
        }
        childrenView.string = rows
        statusField.stringValue = "Last refreshed \(timestampNow()) — auto-refreshes every \(Int(refreshSeconds))s"

        if let window = window {
            window.title = "\(displayName(target.comm)) [\(target.pid)]"
        }
    }

    private func timestampNow() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date())
    }

    // MARK: - Actions

    @objc private func quitClicked() {
        sendSignal(SIGTERM, label: "SIGTERM")
    }

    @objc private func forceQuitClicked() {
        let alert = NSAlert()
        alert.messageText = "Force quit process \(pid)?"
        alert.informativeText = "SIGKILL terminates immediately with no cleanup. Open files, unsaved state, and child processes may be left in inconsistent states."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            sendSignal(SIGKILL, label: "SIGKILL")
        }
    }

    private func sendSignal(_ sig: Int32, label: String) {
        let result = kill(pid_t(pid), sig)
        if result == 0 {
            statusField.stringValue = "Sent \(label) to PID \(pid)"
        } else {
            let err = String(cString: strerror(errno))
            let alert = NSAlert()
            alert.messageText = "kill(\(pid), \(label)) failed"
            alert.informativeText = err
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func closeClicked() {
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose(self)
    }
}
