# Agent context

A tiny macOS menu bar app that surfaces per-UID process count and the
diagnostic state around it, written to prevent a recurrence of the
May 19 2026 incident in which a long-running session pushed the user
past `kern.maxprocperuid` (2666 on this machine) and triggered system-
wide `fork()` EAGAIN — terminals couldn't spawn shells, browsers
couldn't open windows, the only way out was a reboot.

## Build & run

```sh
./scripts/build-app.sh                 # produces build/ProcessMonitor.app
open ~/Applications/ProcessMonitor.app # launch from the dev symlink
```

`~/Applications/ProcessMonitor.app` is a symlink to `build/ProcessMonitor.app`,
created so rebuilds propagate automatically without re-copying and so
`SMAppService.mainApp.register()` (Start at Login) accepts the bundle
location. Don't replace it with a copy unless you have a reason to —
the symlink keeps the dev loop tight.

There are **no unit tests** — this is a GUI app and all verification is
manual. The build script is fast (~3s), so the loop is:
1. Edit
2. `pkill -x ProcessMonitor; ./scripts/build-app.sh; open ~/Applications/ProcessMonitor.app`
3. Click the menu bar item and check.

The build script does an ad-hoc `codesign` pass. **Do not remove it** —
`UNUserNotificationCenter` silently drops notification requests from
unsigned bundles, and threshold alerts will appear to "not fire" if the
signature is missing.

## Layout

- `Sources/ProcessMonitor/main.swift` — entry point, AppDelegate,
  status-item rendering, polling loop, state classes (CountHistory,
  RespawnDetector), top-spawners computation, menu construction.
- `Sources/ProcessMonitor/ProcessDetailWindow.swift` — the floating
  window that opens when you click a Top Spawners entry. Runs its own
  ps refresh on a 2s timer while open; closes its timer in
  `windowWillClose`.
- `Resources/Info.plist` — `LSUIElement=true` (no Dock icon) plus the
  bundle ID `com.nicholaspsmith.ProcessMonitor` that
  `UNUserNotificationCenter` and `SMAppService` rely on.
- `scripts/build-app.sh` — wraps the Swift Package Manager binary in
  a `.app` bundle and ad-hoc signs it.

## Non-obvious decisions (load-bearing)

**Respawn-loop detector uses a ratio, not just a count.** Original
implementation flagged any name with > N distinct PIDs in a 60s window,
which caught every short-lived worker pool on the machine
(mdworker_shared, plugin-container, ExtensionKit helpers, audio
SandboxHelper, *and the monitor's own ps invocation*). The current rule
flags only when `distinct_pids / peak_simultaneous` is high — that
distinguishes "one slot keeps being replaced" (crash loop) from "many
slots turn over normally" (worker pool). `ps` and `<defunct>` are also
on an explicit exclude list. If you tune the thresholds, keep this
distinction in mind: removing the ratio gate brings back the false
positives.

**Sparkline is a view-based NSMenuItem on purpose.** Standard menu
items reserve trailing column space for keyboard-shortcut indicators
(⌘A on "Open Activity Monitor", ⌘Q on "Quit"), and that reservation
applies to every row in the menu — including ones without shortcuts.
Wrapping the sparkline in a custom NSView via `NSMenuItem.view` is the
only way to escape that reservation and let the menu width be driven by
the sparkline content. **Use explicit frames, not auto-layout
constraints**: NSMenu reads the view's frame at insertion time, before
any layout pass would have run, so a constraint-only view ends up
zero-sized and renders as nothing.

**Label width is measured via `NSString.size(withAttributes:)`, not
`NSTextField.intrinsicContentSize`.** The latter returns sub-pixel
widths that get rounded down and clip the trailing glyph (most visible
when the min→max suffix ends in certain digits). Always
`ceil()` + a small buffer (~4px) when sizing a label that's going into
a menu item view.

**Status-item rendering is funnelled through one entry point so the
display can be user-configurable.** All status-item drawing goes through
`renderStatusItem(count:limit:pct:warn:)` (with a `renderSymbol(_:warn:)`
helper); what it produces is driven by two `UserDefaults`-backed enums,
`DisplayMode` and `IconStyle` (keys `displayMode` / `iconStyle`).
They default to `.countTotalPct` / `.gauge`, so existing installs keep
the original `<count>/<limit> (<pct>%)` text behavior untouched. The two
render paths are **mutually exclusive** and must stay that way: text
modes (Count/Total (%), Count/Total, Percent, Icon→Number) draw via
`attributedTitle` — red foreground when usage ≥ `warnPct` — while icon
modes (gauge, chart) draw a template SF Symbol via `button.image`, use
`button.contentTintColor = .systemRed` for the warning state, and swap
to heavier glyph variants (`gauge.with.dots.needle.100percent`,
`chart.bar.fill`) when warning. Set `imagePosition` explicitly on every
path (`.noImage` for text, `.imageOnly` for icons) — otherwise the
unused half leaves stray title spacing in the bar.

**The "Display" submenu is built lazily like the rest of the menu, and
mode changes re-render from cache.** It's assembled in
`menuNeedsUpdate(_:)` alongside everything else; the nested "Icon style"
submenu is only added when `displayMode == iconOnly`, so users never see
icon-style choices that wouldn't apply. Each menu action writes its
UserDefaults key and then calls `rerenderFromCache()` — that repaints
the status item from the last polled values immediately, rather than
making the user wait for the next 5s poll to see their choice take
effect.

**Top spawners excludes PID 1.** launchd is the ancestor of nearly
every userland process, so it would always pin to the top with no
signal. The exclusion is in `topSpawners(_:topN:)`.

**No LaunchAgent for autostart.** The May 19 incident root cause
involved a user-installed LaunchAgent (`com.user.killapplemediatracking`)
in a respawn loop. The "Start at Login" toggle uses `SMAppService.mainApp`
instead — registration is bundle-ID based, requires the app to live in
`/Applications` or `~/Applications`, and macOS manages the lifecycle.

**The hook in `~/.claude/hooks/process-check.sh` is a sibling tool, not
part of this app.** It's a UserPromptSubmit hook installed in
`~/.claude/settings.json` that injects a system reminder into the Claude
session when per-UID usage crosses 60% — a complementary mechanism to
this app's menu-bar notification. Editing files under `~/.claude/hooks/`
is blocked by the auto-mode classifier (treated as agent
self-modification); use Write rather than Edit if you need to change
it, and expect that to require explicit user permission.

## Things to avoid

- **Don't add a curated "problematic processes" list.** The user
  explicitly rejected this in favor of the more general respawn-loop
  detector. Names go stale; behavior-based detection doesn't.
- **Don't lower the kill-confirmation bar.** Force Quit (SIGKILL) shows
  an NSAlert; Quit (SIGTERM) doesn't. That matches Activity Monitor's
  pattern and the user has accepted it.
- **Don't switch the build to Xcode.** Swift Package Manager + the
  build script is the deliberate setup — keeps the source tree
  CLI-friendly and the dev loop fast.
- **Don't restore `Refresh now` to the menu.** It was removed because
  5s polling makes it redundant clutter. The detail window has its own
  Refresh button (2s auto-refresh + manual) because that data is
  view-specific and the user wants explicit control.

## Behavior expectations

- Status bar text shows `<count>/<limit> (<pct>%)`, monospaced digits.
  Goes red at ≥ 85% with a 5pt hysteresis on the notification so a
  single bounce around the threshold doesn't spam.
- Menu rebuild is lazy via `NSMenuDelegate.menuNeedsUpdate(_:)`. The
  5s polling loop updates the internal state buffers (CountHistory,
  RespawnDetector, latest ProcRec array); the menu only re-reads them
  when the user clicks.
- Crash-looping submenu header is omitted entirely when the detector
  returns nothing, by design. The user shouldn't see a section that's
  just `(none)`.
