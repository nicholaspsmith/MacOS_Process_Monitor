# Customizable Menu Bar Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose how the menu bar status item is rendered — count/total (%), count/total, percent, or an icon (gauge / chart / bare number) — to reduce horizontal space, via a "Display" submenu, persisted across launches.

**Architecture:** Two `UserDefaults`-backed enums (`DisplayMode`, `IconStyle`) drive a new `renderStatusItem(count:limit:pct:warn:)` method extracted from `refresh()`. The lazy menu (`menuNeedsUpdate`) gains a "Display" submenu (radio group) with a nested "Icon style" submenu shown only in icon mode. Menu actions write the setting and re-render immediately from cached state.

**Tech Stack:** Swift, AppKit (`NSStatusItem`, `NSMenu`, `NSImage` SF Symbols), `UserDefaults`. No new dependencies.

**Verification note:** This project has **no unit tests** by design (GUI app, manual verification — see CLAUDE.md). Each task is verified by the build-and-click loop:
```sh
pkill -x ProcessMonitor; ./scripts/build-app.sh && open ~/Applications/ProcessMonitor.app
```
Then click the menu bar item to observe. The build script (~3s) ad-hoc signs the bundle — do not bypass it.

---

### Task 1: Add the settings enums and persisted accessors

**Files:**
- Modify: `Sources/ProcessMonitor/main.swift` (add enums near top-level, before `AppDelegate`; add computed accessors as `AppDelegate` members near `main.swift:203`)

- [ ] **Step 1: Add the two enums**

Add at file scope (e.g. just above `class AppDelegate` — anywhere top-level is fine). Each falls back to its default when the stored string is missing/unrecognized.

```swift
enum DisplayMode: String {
    case countTotalPct   // "1234/2666 (46%)"  — default
    case countTotal      // "1234/2666"
    case percent         // "46%"
    case iconOnly        // SF Symbol or bare number, per IconStyle

    static let storageKey = "displayMode"
    static var current: DisplayMode {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(DisplayMode.init) ?? .countTotalPct }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

enum IconStyle: String {
    case gauge           // gauge SF Symbol — default
    case chart           // chart.bar SF Symbol
    case number          // bare percent number, no "%"

    static let storageKey = "iconStyle"
    static var current: IconStyle {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(IconStyle.init) ?? .gauge }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./scripts/build-app.sh`
Expected: builds cleanly, produces `build/ProcessMonitor.app`. No behavior change yet.

- [ ] **Step 3: Commit**

```bash
git add Sources/ProcessMonitor/main.swift
git commit -m "Add DisplayMode/IconStyle settings enums"
```

---

### Task 2: Extract status-item rendering into `renderStatusItem`

**Files:**
- Modify: `Sources/ProcessMonitor/main.swift:402-410` (the inline rendering inside `refresh()`)

- [ ] **Step 1: Add the `renderStatusItem` method**

Add a new private method on `AppDelegate` (e.g. directly below `refresh()`). This handles all modes. `warn` is the high-usage flag (`pct >= warnPct`).

```swift
private func renderStatusItem(count: Int, limit: Int, pct: Int, warn: Bool) {
    guard let button = statusItem.button else { return }
    let mode = DisplayMode.current

    // Helper to render text and clear any image.
    func renderText(_ s: String) {
        button.image = nil
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
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: "Process usage")?
        .withSymbolConfiguration(config)
    image?.isTemplate = true
    button.image = image
    button.contentTintColor = warn ? .systemRed : nil
}
```

- [ ] **Step 2: Replace the inline rendering in `refresh()`**

In `refresh()`, replace the block at `main.swift:403-410`:

```swift
        let pct = count * 100 / limit
        let color: NSColor = pct >= warnPct ? .systemRed : .labelColor
        statusItem.button?.attributedTitle = NSAttributedString(
            string: "\(count)/\(limit) (\(pct)%)",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            ]
        )
```

with:

```swift
        let pct = count * 100 / limit
        renderStatusItem(count: count, limit: limit, pct: pct, warn: pct >= warnPct)
```

(Leave the notification block at `main.swift:412-419` untouched — it still uses `pct` and `warnPct`.)

- [ ] **Step 3: Build, run, and verify default behavior unchanged**

Run: `pkill -x ProcessMonitor; ./scripts/build-app.sh && open ~/Applications/ProcessMonitor.app`
Expected: menu bar still shows `<count>/<limit> (<pct>%)` in monospaced digits, exactly as before (default `DisplayMode` is `.countTotalPct`). No regression.

- [ ] **Step 4: Commit**

```bash
git add Sources/ProcessMonitor/main.swift
git commit -m "Extract status-item rendering into renderStatusItem"
```

---

### Task 3: Add the "Display" submenu and actions

**Files:**
- Modify: `Sources/ProcessMonitor/main.swift` — insert submenu construction in `menuNeedsUpdate` before the "Open Activity Monitor" item (`main.swift:303`); add `@objc` action methods on `AppDelegate`.

- [ ] **Step 1: Add menu construction in `menuNeedsUpdate`**

Insert immediately before the line `menu.addItem(NSMenuItem.separator())` that precedes "Open Activity Monitor" (`main.swift:302`):

```swift
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
```

- [ ] **Step 2: Add the two action methods**

Add as `@objc private` methods on `AppDelegate` (e.g. near `openActivityMonitor` at `main.swift:383`). They write the setting and re-render from cached state so the change is instant.

```swift
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
```

- [ ] **Step 3: Build, run, and verify all modes**

Run: `pkill -x ProcessMonitor; ./scripts/build-app.sh && open ~/Applications/ProcessMonitor.app`
Then click the menu bar item → "Display" and verify:
- Each of the 4 modes is selectable, shows a checkmark when active, and changes the status bar text instantly.
  - `Count / Total (%)` → e.g. `1234/2666 (46%)`
  - `Count / Total` → e.g. `1234/2666`
  - `Percent` → e.g. `46%`
  - `Icon only` → a gauge glyph (default icon style)
- With `Icon only` active, the nested "Icon style" submenu appears and offers Gauge / Chart / Number; switching shows the gauge symbol, the bar-chart symbol, or the bare percent number respectively.
- Quit and relaunch → the chosen mode/style persists.

- [ ] **Step 4: Commit**

```bash
git add Sources/ProcessMonitor/main.swift
git commit -m "Add Display submenu for menu bar mode and icon style"
```

---

### Task 4: Verify the high-usage warning cue across modes

**Files:** none (verification + tuning only)

- [ ] **Step 1: Build and run**

Run: `pkill -x ProcessMonitor; ./scripts/build-app.sh && open ~/Applications/ProcessMonitor.app`

- [ ] **Step 2: Verify warning rendering**

The warning fires at `pct >= warnPct` (85). If current usage is below that, temporarily lower `warnPct` (`main.swift:204`) to a value just under current usage to observe, then restore it. Verify:
- Text modes (Count/Total (%), Count/Total, Percent, and Icon → Number): text turns **red**.
- Icon modes (Gauge, Chart): glyph turns **red** and switches to the heavier/filled variant (`gauge.with.dots.needle.100percent`, `chart.bar.fill`).
- Below the threshold: text returns to label color; icon returns to template (adaptive) tint.

If `warnPct` was changed for testing, restore it to `85` and rebuild.

- [ ] **Step 3: Commit (only if `warnPct` or symbol names were tuned)**

```bash
git add Sources/ProcessMonitor/main.swift
git commit -m "Tune warning-state symbols for icon display modes"
```

(If nothing changed in this task, skip the commit.)

---

### Task 5: Update CLAUDE.md with the new load-bearing decisions

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Document the display-mode setting**

Add a bullet under "Non-obvious decisions (load-bearing)" capturing:
- The status-item rendering goes through `renderStatusItem(count:limit:pct:warn:)`; `DisplayMode`/`IconStyle` are `UserDefaults`-backed enums defaulting to `.countTotalPct` / `.gauge` to preserve prior behavior.
- Icon modes use template SF Symbols + `contentTintColor` for the red warning state and swap to heavier glyph variants; text modes use red foreground.
- The "Display" submenu is rebuilt lazily in `menuNeedsUpdate` like the rest of the menu; the nested "Icon style" submenu only appears when `displayMode == iconOnly`.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Document customizable menu bar display in CLAUDE.md"
```

---

## Self-Review

**Spec coverage:**
- `displayMode` / `iconStyle` enums + persistence → Task 1. ✓
- Rendering switch for all 6 outputs → Task 2. ✓
- Text vs image mutual exclusivity, monospaced font, template images → Task 2. ✓
- Warning cue (text red; icon red + filled variant; tint cleared otherwise) → Task 2 (implementation) + Task 4 (verification). ✓
- "Display" submenu + nested "Icon style", radio checkmarks, instant re-render → Task 3. ✓
- Notification/hysteresis untouched → Task 2 Step 2 note. ✓
- Error/initial states stay text → unchanged code paths (`"…"`, `"ps?"`), not modified by any task. ✓

**Placeholder scan:** No TBD/TODO; all code shown in full. ✓

**Type consistency:** `DisplayMode`/`IconStyle` `.current` accessors, `renderStatusItem(count:limit:pct:warn:)`, `renderSymbol(_:warn:)`, `rerenderFromCache()`, and `representedObject` as `String` rawValue are used consistently across Tasks 1–3. ✓
