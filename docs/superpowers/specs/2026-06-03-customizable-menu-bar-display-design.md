# Customizable menu bar display

## Problem

The status-item title is always `<count>/<limit> (<pct>%)` (e.g. `1234/2666 (46%)`),
rendered in `refresh()` at `main.swift:404`. This takes up a lot of horizontal
space in the menu bar. Give the user a way to choose a more compact
representation, including data-driven icons.

## Setting

One setting, persisted in `UserDefaults.standard`:

- **`displayMode`** — `String`, one of:
  - `countTotalPct` *(default — preserves current behavior)*
  - `countTotal`
  - `percent`
  - `gauge`  *(custom-drawn gauge icon)*
  - `pie`    *(custom-drawn pie icon)*

Modeled as a Swift enum `DisplayMode` with `rawValue` strings and a fallback to
the default when the stored value is missing or unrecognized. There is **no**
separate icon-style sub-setting and **no** nested submenu — the gauge and pie
are top-level choices in a single flat radio group.

## Rendering

Extract the status-item update currently inline in `refresh()` into a method:

```
renderStatusItem(count: Int, limit: Int, pct: Int, warn: Bool)
```

`refresh()` computes `count`/`pct`/`warn` (as it does now) and calls it. The
menu action that changes the setting also calls it (via `rerenderFromCache()`),
using the cached `latestCount` and `limit`, so the change is instant without
waiting for the next 5s poll.

Switch on `displayMode`:

| Mode            | Output (example at 1234 / 2666, 46%)         | Mechanism |
|-----------------|----------------------------------------------|-----------|
| `countTotalPct` | `1234/2666 (46%)`                            | `attributedTitle`, image cleared |
| `countTotal`    | `1234/2666`                                  | `attributedTitle`, image cleared |
| `percent`       | `46%`                                        | `attributedTitle`, image cleared |
| `gauge`         | speedometer needle at ~46% of the arc        | `button.image` (custom-drawn), title cleared |
| `pie`           | circle outline with a ~46% filled wedge      | `button.image` (custom-drawn), title cleared |

- Text modes keep the existing monospaced-digit font
  (`NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)`).
- The text path and the image path are **mutually exclusive**. Text path:
  `button.image = nil`, `button.imagePosition = .noImage`,
  `button.contentTintColor = nil`, then set `attributedTitle`. Image path:
  `attributedTitle = NSAttributedString(string: "")`,
  `button.imagePosition = .imageOnly`, then set `button.image`.

### Data-driven icons (custom-drawn)

Both icons are drawn into an `NSImage` (≈18×18 pt) via
`NSImage(size:flipped:drawingHandler:)` using `NSBezierPath`, and marked
`isTemplate = true` so the menu bar tints them appropriately for light/dark.
Because they are template images, the *shape* encodes the data and emphasis;
*color* (including the red warning state) is applied by the menu bar tint /
`button.contentTintColor`, not by the drawing.

- **Gauge** — a speedometer-style arc (≈220° sweep, open at the bottom) with a
  needle whose angle is interpolated linearly from the arc start (0%) to the
  arc end (100%) by `pct`. A small center hub anchors the needle.
- **Pie** — a full circle outline representing the per-UID cap; a filled wedge
  starting at 12 o'clock and sweeping clockwise by `pct/100 × 360°` represents
  the processes currently in use.

`pct` is clamped to `0...100` before use.

## Warning cue (≥ 85%)

The existing notification logic and its 5pt hysteresis (`main.swift:412–419`)
are **unchanged**. This covers only the visual cue on the status item, driven
by the `warn` flag (`pct >= warnPct`):

- **Text modes**: red foreground color, exactly as today.
- **Icon modes** (`gauge`, `pie`): tint red via
  `button.contentTintColor = .systemRed` **and** draw with bolder emphasis
  (thicker strokes; the pie's filled wedge extends closer to the rim). When not
  warning, `contentTintColor = nil` so the template glyph stays adaptive and
  the strokes are drawn at their normal weight.

## Menu

Built in `menuNeedsUpdate(_:)` alongside the rest of the menu, inserted before
"Open Activity Monitor". Pattern mirrors the existing "Start at Login" toggle:
read the current setting to set checkmark state; the action writes the setting
and re-renders.

- A single **"Display"** submenu containing one radio group of 5 items
  (`Count / Total (%)`, `Count / Total`, `Percent`, `Gauge`, `Pie`). The active
  mode shows `.state = .on`.
- The action (`setDisplayMode(_:)`) reads `representedObject` (the mode
  `rawValue`), writes `DisplayMode.current`, and calls `rerenderFromCache()`.

## Error / initial states

- The `applicationDidFinishLaunching` placeholder (`"…"`) and the `ps?` error
  state remain text regardless of mode — they are not normal renders.

## Out of scope

- No new dependencies; no Settings/Preferences window — the menu is the UI.
- No change to polling cadence, sparkline, crash-loop detector, or top
  spawners.
