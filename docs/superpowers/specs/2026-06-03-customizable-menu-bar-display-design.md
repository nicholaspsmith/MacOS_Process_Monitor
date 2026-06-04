# Customizable menu bar display

## Problem

The status-item title is always `<count>/<limit> (<pct>%)` (e.g. `1234/2666 (46%)`),
rendered in `refresh()`. This takes up a lot of horizontal space in the menu
bar. Give the user a way to choose a more compact representation, including
data-driven icons.

## Setting

One setting, persisted in `UserDefaults.standard`:

- **`displayMode`** — `String`, one of:
  - `countTotalPct` *(default — preserves current behavior)*
  - `countTotal`
  - `percent`
  - `gauge`  *(custom-drawn needle gauge)*
  - `arc`    *(custom-drawn filled radial arc)*
  - `pie`    *(custom-drawn pie: outline + wedge)*
  - `wedge`  *(custom-drawn pie: solid wedge on a faint disk)*

Modeled as a Swift enum `DisplayMode` with `rawValue` strings and a fallback to
the default when the stored value is missing or unrecognized. There is **no**
separate icon-style sub-setting and **no** nested submenu — the four icons are
top-level choices in a single flat radio group.

## Rendering

The status-item update lives in a method extracted out of `refresh()`:

```
renderStatusItem(count: Int, limit: Int, pct: Int, warn: Bool)
```

`refresh()` computes `count`/`pct`/`warn` (as it does now) and calls it. The
menu action that changes the setting also calls it (via `rerenderFromCache()`),
using the cached `latestCount` and `limit`, so the change is instant without
waiting for the next 5s poll.

Switch on `displayMode`:

| Mode            | Output (example at 1234 / 2666, 46%)              | Mechanism |
|-----------------|---------------------------------------------------|-----------|
| `countTotalPct` | `1234/2666 (46%)`                                 | `attributedTitle`, image cleared |
| `countTotal`    | `1234/2666`                                       | `attributedTitle`, image cleared |
| `percent`       | `46%`                                             | `attributedTitle`, image cleared |
| `gauge`         | speedometer needle at ~46% of the arc             | `button.image` (custom-drawn), title cleared |
| `arc`           | ~250° track with a bold arc filled to ~46%        | `button.image` (custom-drawn), title cleared |
| `pie`           | circle outline with a ~46% filled wedge           | `button.image` (custom-drawn), title cleared |
| `wedge`         | solid ~46% wedge on a faint full disk             | `button.image` (custom-drawn), title cleared |

- Text modes keep the existing monospaced-digit font
  (`NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)`).
- The text path and the image path are **mutually exclusive**. Text path
  (`renderText`): `button.image = nil`, `button.imagePosition = .noImage`,
  `button.contentTintColor = nil`, then set `attributedTitle`. Image path
  (`renderIcon`): `attributedTitle = NSAttributedString(string: "")`,
  `button.imagePosition = .imageOnly`, `button.contentTintColor = nil`, then
  set `button.image`.

### Data-driven icons (custom-drawn)

Each icon is built with `NSImage(size:flipped:drawingHandler:)` (18×18) in a
`make…Image(pct:)` function using `NSBezierPath`. The arc sweep, needle angle,
or wedge angle is sized directly from `pct` (i.e. `count/limit`), so the glyph
reflects live usage and updates on each 5s poll.

- **`gauge`** — a ~250° arc (open at the bottom) with a needle whose angle
  interpolates from the arc start (0%) to the arc end (100%), plus a center hub.
- **`arc`** — the same ~250° arc drawn as a faint full track with a bold arc
  stroked from the start up to the current fraction.
- **`pie`** — a circle outline (the per-UID cap) with a filled wedge from 12
  o'clock, clockwise, proportional to `pct`.
- **`wedge`** — a faint full disk (the cap) with a solid wedge from 12 o'clock,
  clockwise, proportional to `pct`.

Icons are **non-template** (`isTemplate = false`) because color carries
information. `meterColor(pct:)` returns the drawing color:

- green below 50%
- orange from 50% up to `warnPct` (85)
- red at/above `warnPct`

The faint track / remainder is the same hue at ~0.28 alpha so each glyph reads
as a single object. (SF Symbols were considered first but cannot render a
data-proportional fill, which is why the icons are hand-drawn.)

## Warning cue (≥ 85%)

The existing notification logic and its 5pt hysteresis are **unchanged**. This
covers only the visual cue on the status item, driven by `pct`:

- **Text modes**: red foreground color when `pct >= warnPct`, exactly as today.
- **Icon modes**: no special-case red tint — the severity color from
  `meterColor(pct:)` is already red at/above `warnPct`, so the icon turns red as
  part of the normal green→orange→red progression.

## Menu

Built in `menuNeedsUpdate(_:)` alongside the rest of the menu, inserted before
"Open Activity Monitor". Pattern mirrors the existing "Start at Login" toggle:
read current setting to set checkmark state, action writes the setting and
re-renders.

- **"Display"** submenu: a single flat radio group for `displayMode`. The active
  mode shows `.state = .on`. Labels: `Count / Total (%)`, `Count / Total`,
  `Percent`, `Gauge (needle)`, `Gauge (arc)`, `Pie (outline)`, `Pie (filled)`.
- Each item: `target = self`, an `@objc` action (`setDisplayMode(_:)`) that
  writes the UserDefaults key (the chosen `rawValue` is carried in
  `representedObject`) and calls `rerenderFromCache()`.

## Error / initial states

- The `applicationDidFinishLaunching` placeholder (`"…"`) and the `ps?` error
  state remain text regardless of mode — they are not normal renders.

## Out of scope

- No new dependencies; no Settings/Preferences window — the menu is the UI.
- No change to polling cadence, sparkline, crash-loop detector, or top
  spawners.
