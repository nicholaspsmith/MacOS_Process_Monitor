# ProcessMonitor → StatusItemKit retrofit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retrofit the existing ProcessMonitor app onto StatusItemKit — move its pure logic into a unit-tested `ProcessMonitorCore` library and replace its hand-rolled status-item/icon/login/notification plumbing with StatusItemKit — **without changing any user-visible behavior.**

**Architecture:** SwiftPM package gains a `ProcessMonitorCore` library target (pure parsing/logic, no AppKit) + `ProcessMonitorCoreTests`; the existing `ProcessMonitor` executable target now depends on `ProcessMonitorCore` + StatusItemKit. The duplicated icon drawing, status-item lifecycle, login-item, and notifier code is deleted from the app and replaced with StatusItemKit's (`StatusItemController`, `MeterIcon`, `Severity`, `LoginItem`, `Notifier`, `MenuBuilder`, `Shell`). `ProcessDetailWindow.swift` stays app-specific.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, StatusItemKit v0.1.0 (local path), macOS 13+.

## Global Constraints

- Work on a feature branch: `git checkout -b statusitemkit-retrofit` first.
- **Behavior must not change.** This app exists to prevent a recurrence of the May 19 2026 fork()-EAGAIN incident; preserve every load-bearing decision documented in `CLAUDE.md`, in particular:
  - Respawn detector uses the **`distinct/peak` churn ratio**, not a raw count, with `ps`/`<defunct>` excluded. Do not regress to count-only.
  - Sparkline is a **view-based NSMenuItem** with explicit frames + `NSString.size` measurement (use StatusItemKit's `MenuBuilder.textView`).
  - Status rendering funnels through one path; **text modes vs icon modes are mutually exclusive** (`imagePosition` set explicitly).
  - The four data-driven icons are **full-color, non-template**, color = severity (green <50%, orange <85%, red ≥85%). These map exactly to StatusItemKit `MeterIcon` + `Severity`.
  - Top spawners **excludes PID 1**. Crash-loop section omitted entirely when empty. No "Refresh now" item. Start-at-Login via `SMAppService` (not a LaunchAgent). Kill-confirmation bar unchanged (handled in `ProcessDetailWindow`, untouched).
  - The build script keeps the **ad-hoc codesign** (notifications break unsigned).
- StatusItemKit dependency via **local path**: `.package(path: "../StatusItemKit")`. Keep bundle id `com.nicholaspsmith.ProcessMonitor`, `LSUIElement` true.
- Git: atomic commits per task; messages end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Reference: the current `Sources/ProcessMonitor/main.swift` (the logic being extracted) and `CLAUDE.md` (load-bearing decisions). `ProcessDetailWindow.swift` is NOT modified.

## Notes on what maps to StatusItemKit (delete the app's copies, use these)

| App's current code | Replace with |
|---|---|
| `readAllProcs()` Process plumbing | `Shell.run("/bin/ps", ["-axo","pid,ppid,user,etime,comm","-ww"])` + pure `parseProcs(_:)` |
| `makeGaugeImage/makeArcImage/makePieImage/makeWedgeImage` | `MeterIcon.gauge/arc/pie/wedge(fraction:color:)` |
| `meterColor(pct:)` | `Severity.level(pct:warnPct:85).color` |
| AppDelegate status-item + Timer + `menuNeedsUpdate` boilerplate | `StatusItemController(pollInterval:onPoll:onBuildMenu:)` |
| `renderStatusItem`/`renderIcon` text/icon funnel | `controller.setTitle(_:warn:)` / `controller.setIcon(_:)` |
| `makeSparklineView` | `MenuBuilder.textView(_:font:)` |
| `toggleLoginItem` + alert | `LoginItem.toggle()` / `LoginItem.isEnabled` |
| `notify(...)` UNUserNotificationCenter | `Notifier.post(title:body:)` + `requestAuthorization()` |

`readProcessLimit()` (sysctl) stays in the app. `DisplayMode` (UserDefaults-backed) stays in the app. `ProcessDetailWindow.swift` unchanged.

---

### Task 1: Branch + Package skeleton + `parseProcs`

**Files:**
- Create branch; Modify: `Package.swift`
- Create: `Sources/ProcessMonitorCore/ProcRec.swift`
- Test: `Tests/ProcessMonitorCoreTests/ParseProcsTests.swift`

**Interfaces:**
- Produces:
  - `struct ProcRec: Equatable { let pid: Int; let ppid: Int; let user: String; let etime: String; let comm: String }` (public init)
  - `func parseProcs(_ psOutput: String) -> [ProcRec]` — the parsing body of the current `readAllProcs()` (split lines, drop header, `maxSplits: 4`, require 5 tokens, Int pid/ppid). Pure; takes the `ps` text.
  - `func displayName(_ comm: String) -> String` — strip path + leading `-` (from current main.swift).

- [ ] **Step 1: Update `Package.swift`** — add `ProcessMonitorCore` library target + `ProcessMonitorCoreTests`, add the StatusItemKit dependency, and make the `ProcessMonitor` executable depend on both:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProcessMonitor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "ProcessMonitorCore"),
        .executableTarget(
            name: "ProcessMonitor",
            dependencies: ["ProcessMonitorCore", .product(name: "StatusItemKit", package: "StatusItemKit")],
            path: "Sources/ProcessMonitor"
        ),
        .testTarget(name: "ProcessMonitorCoreTests", dependencies: ["ProcessMonitorCore"]),
    ]
)
```

- [ ] **Step 2: Write the failing test** `Tests/ProcessMonitorCoreTests/ParseProcsTests.swift`

```swift
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
```

- [ ] **Step 3: Run, verify fail** — `swift test --filter ParseProcsTests` → FAIL (undefined).

- [ ] **Step 4: Implement `Sources/ProcessMonitorCore/ProcRec.swift`** — move `ProcRec`, the parsing body of `readAllProcs()` (as `parseProcs(_:)` taking the text), and `displayName(_:)` from `main.swift`. Make the type + functions `public` with a public `ProcRec` init.

- [ ] **Step 5: Run, verify pass** — PASS (3 tests).

- [ ] **Step 6: Commit** (`feat: ProcessMonitorCore — parseProcs + ProcRec`, with trailer).

---

### Task 2: `topSpawners` (PID-1 exclusion preserved)

**Files:** Create `Sources/ProcessMonitorCore/TopSpawners.swift`; Test `Tests/ProcessMonitorCoreTests/TopSpawnersTests.swift`

**Interfaces:** `func topSpawners(_ all: [ProcRec], topN: Int) -> [(comm: String, pid: Int, descendants: Int)]` — descendant counting via PPID graph, **excludes PID 1**, sorted desc (exact logic from current main.swift).

- [ ] **Step 1: Failing test** — build a small `[ProcRec]` tree and assert descendant counts + that PID 1 is excluded even though it's the ancestor:

```swift
import XCTest
@testable import ProcessMonitorCore

final class TopSpawnersTests: XCTestCase {
    func testCountsDescendantsAndExcludesPID1() {
        let procs = [
            ProcRec(pid: 1, ppid: 0, user: "root", etime: "", comm: "launchd"),
            ProcRec(pid: 10, ppid: 1, user: "nick", etime: "", comm: "parent"),
            ProcRec(pid: 11, ppid: 10, user: "nick", etime: "", comm: "child"),
            ProcRec(pid: 12, ppid: 11, user: "nick", etime: "", comm: "grandchild"),
        ]
        let top = topSpawners(procs, topN: 10)
        XCTAssertNil(top.first { $0.pid == 1 })            // PID 1 excluded
        let parent = top.first { $0.pid == 10 }
        XCTAssertEqual(parent?.descendants, 2)             // 11 + 12
    }
}
```

- [ ] **Step 2–5:** verify fail → move `topSpawners` from main.swift into the new file (public) → verify pass → commit (`feat: ProcessMonitorCore — topSpawners`).

---

### Task 3: `CountHistory` (sparkline)

**Files:** Create `Sources/ProcessMonitorCore/CountHistory.swift`; Test `Tests/ProcessMonitorCoreTests/CountHistoryTests.swift`

**Interfaces:** `final class CountHistory { init(maxLen:); func record(_:); func sparkline() -> String; var range: (min: Int, max: Int)? }` (moved verbatim, made public).

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import ProcessMonitorCore

final class CountHistoryTests: XCTestCase {
    func testSparklineLengthAndRange() {
        let h = CountHistory(maxLen: 25)
        [10, 20, 30].forEach { h.record($0) }
        XCTAssertEqual(h.sparkline().count, 3)
        XCTAssertEqual(h.range?.min, 10)
        XCTAssertEqual(h.range?.max, 30)
    }
    func testTrimsToMaxLen() {
        let h = CountHistory(maxLen: 2)
        [1, 2, 3].forEach { h.record($0) }
        XCTAssertEqual(h.range?.min, 2)   // first dropped
    }
}
```

- [ ] **Step 2–5:** verify fail → move `CountHistory` (public) → verify pass → commit (`feat: ProcessMonitorCore — CountHistory`).

---

### Task 4: `RespawnDetector` (churn-ratio gate)

**Files:** Create `Sources/ProcessMonitorCore/RespawnDetector.swift`; Test `Tests/ProcessMonitorCoreTests/RespawnDetectorTests.swift`

**Interfaces:** `final class RespawnDetector { init(windowSize:minDistinct:minChurnRatio:); func record(_ procs: [ProcRec]); func looping() -> [Looping] }`, `struct Looping { let comm: String; let distinct: Int; let peak: Int }` (moved verbatim, public). **Preserve the `distinct/peak` ratio gate and the `ps`/`<defunct>` exclusions.**

- [ ] **Step 1: Failing test** — this is the load-bearing distinction; test BOTH sides:

```swift
import XCTest
@testable import ProcessMonitorCore

final class RespawnDetectorTests: XCTestCase {
    private func rec(_ pid: Int, _ comm: String) -> ProcRec { ProcRec(pid: pid, ppid: 1, user: "nick", etime: "", comm: comm) }

    func testFlagsCrashLoopOneSlotManyPids() {
        let d = RespawnDetector(windowSize: 12, minDistinct: 5, minChurnRatio: 5)
        // one live at a time, replaced each poll -> peak 1, distinct large
        for pid in 100..<112 { d.record([rec(pid, "crasher")]) }
        XCTAssertTrue(d.looping().contains { $0.comm == "crasher" })
    }
    func testDoesNotFlagWorkerPool() {
        let d = RespawnDetector(windowSize: 12, minDistinct: 5, minChurnRatio: 5)
        // many live simultaneously, modest turnover -> high peak, low ratio
        for i in 0..<12 {
            d.record((0..<8).map { rec(1000 + i + $0 * 100, "mdworker_shared") })
        }
        XCTAssertFalse(d.looping().contains { $0.comm == "mdworker_shared" })
    }
    func testExcludesPsAndDefunct() {
        let d = RespawnDetector(windowSize: 12, minDistinct: 5, minChurnRatio: 5)
        for pid in 200..<212 { d.record([rec(pid, "/bin/ps"), rec(pid + 1000, "<defunct>")]) }
        XCTAssertTrue(d.looping().isEmpty)
    }
}
```

- [ ] **Step 2–5:** verify fail → move `RespawnDetector` (public) → verify pass (all 3) → commit (`feat: ProcessMonitorCore — RespawnDetector with churn-ratio gate`).

---

### Task 5: Rewrite the app onto StatusItemKit (build + manual verify)

**Files:** Modify `Sources/ProcessMonitor/main.swift` (major); `ProcessDetailWindow.swift` unchanged.

- [ ] **Step 1: Rewrite `main.swift`** keeping behavior identical, using the mapping table above:
  - Keep `readProcessLimit()` and `DisplayMode` in this file.
  - Replace AppDelegate's status-item/Timer/`menuNeedsUpdate` with a `StatusItemController`. Move the menu construction into the `onBuildMenu` closure (sparkline via `MenuBuilder.textView`, crash-loop submenu omitted when empty, top-spawners submenu with the detail-window action, Display radio submenu, Open Activity Monitor, Start at Login via `LoginItem`, Quit).
  - `onPoll`: `Shell.run` ps → `parseProcs` → count for `NSUserName()` → `history.record` / `respawn.record` → render. Render via a single funnel: text modes → `controller.setTitle("\(count)/\(limit) (\(pct)%)", warn: pct >= 85)` etc.; icon modes → `controller.setIcon(MeterIcon.arc(fraction: CGFloat(pct)/100, color: Severity.level(pct: pct, warnPct: 85).color))` (and gauge/pie/wedge). Keep the `displayMode` switch + `rerenderFromCache()` behavior (re-render immediately on mode change from last polled values).
  - Threshold notification: `Notifier` with the same ≥85% + 5pt hysteresis logic and message text.
  - Delete `makeGaugeImage/makeArcImage/makePieImage/makeWedgeImage`, `meterColor`, `makeSparklineView`, `renderIcon`, the manual `notify`, `toggleLoginItem` alert — all now from StatusItemKit. Keep `showSpawnerDetail` (opens `ProcessDetailWindowController`, unchanged).

- [ ] **Step 2: Switch `scripts/build-app.sh`** to call the shared builder (dogfood StatusItemKit):

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh ProcessMonitor
```

- [ ] **Step 3: Build** — `./scripts/build-app.sh` → `build/ProcessMonitor.app`; confirm `codesign -dv` shows `Signature=adhoc`.

- [ ] **Step 4: Run Core tests** — `swift test` → all ProcessMonitorCore tests PASS.

- [ ] **Step 5: Manual verification** (behavior parity — open and click through):
  - Status bar shows `<count>/<limit> (<pct>%)` monospaced; goes red ≥85%.
  - Display submenu: all 3 text + 4 icon modes work; switching re-renders immediately; icon colors track severity (green/orange/red).
  - Sparkline row renders full width (no clipped trailing glyph); `min→max` suffix correct.
  - Top spawners submenu (no PID 1); clicking an entry opens the detail window (kill actions still work).
  - Crash-loop section appears only when the detector fires (won't normally).
  - Start at Login toggles; Open Activity Monitor works; Quit works.
  - Threshold notification still fires (test by temporarily lowering `warnPct` if needed, then revert).
  Then `pkill -x ProcessMonitor`.

- [ ] **Step 6: Commit** (`feat: retrofit app onto StatusItemKit`, with trailer).

---

### Task 6: Docs + .gitignore

- [ ] **Step 1:** Update `CLAUDE.md`'s layout/architecture notes to mention `ProcessMonitorCore` and that status-item/icon/login/notification plumbing now comes from StatusItemKit (keep all the load-bearing-decision notes — they still hold, just relocated). Ensure `.gitignore` covers `.build/`, `build/`, `*.app`, `.swiftpm/`.
- [ ] **Step 2: Commit** (`docs: note StatusItemKit retrofit + ProcessMonitorCore`, with trailer).

---

## Self-review checklist (before reporting done)

- `swift test` green (parseProcs, topSpawners, CountHistory, RespawnDetector — including the worker-pool-vs-crash-loop distinction).
- `./scripts/build-app.sh` builds + ad-hoc-signs `build/ProcessMonitor.app`.
- No behavior change vs. the documented spec; `ProcessDetailWindow.swift` untouched.
- All work on the `statusitemkit-retrofit` branch; nothing pushed.
