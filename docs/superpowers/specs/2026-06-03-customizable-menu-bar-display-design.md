# Customizable menu bar display

## Problem

The status-item title is always `<count>/<limit> (<pct>%)` (e.g. `1234/2666 (46%)`),
rendered in `refresh()` at `main.swift:404`. This takes up a lot of horizontal
space in the menu bar. Give the user a way to choose a more compact
representation.

## Settings

Two settings, persisted in `UserDefaults.standard`:

- **`displayMode`** — `String`, one of:
  - `countTotalPct` *(default — preserves current behavior)*
  - `countTotal`
  - `percent`
  - `iconOnly`
- **`iconStyle`** — `String`, one of:
  - `gauge` *(default)*
  - `chart`
  - `number`

  Only consulted when `displayMode == iconOnly`.

Both are modeled as Swift enums (e.g. `DisplayMode`, `IconStyle`) with
`rawValue` strings and a fallback to the default when the stored value is
missing or unrecognized.

## Rendering

Extract the status-item update currently inline in `refresh()` into a method:

```
renderStatusItem(count: Int, limit: Int, pct: Int, warn: Bool)
```

`refresh()` computes `count`/`pct`/`warn` (as it does now) and calls it. Menu
actions that change a setting also call it, using the cached `latestCount` and
`limit`, so the change is instant without waiting for the next 5s poll.

Switch on `displayMode`:

| Mode             | Output (example at 1234 / 2666, 46%)            | Mechanism |
|------------------|-------------------------------------------------|-----------|
| `countTotalPct`  | `1234/2666 (46%)`                               | `attributedTitle`, image cleared |
| `countTotal`     | `1234/2666`                                     | `attributedTitle`, image cleared |
| `percent`        | `46%`                                           | `attributedTitle`, image cleared |
| `iconOnly`+`gauge` | gauge SF Symbol                               | `button.image`, `attributedTitle` cleared |
| `iconOnly`+`chart` | `chart.bar` SF Symbol                         | `button.image`, `attributedTitle` cleared |
| `iconOnly`+`number`| `46` (bare number, no `%`)                    | `attributedTitle`, image cleared |

- Text modes keep the existing monospaced-digit font
  (`NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)`).
- When setting an image, set `attributedTitle` to empty; when setting text,
  set `button.image = nil`. Only one of the two is ever active.
- Icon images are template images (`isTemplate = true`) so they adapt to
  light/dark menu bar. Symbol config: `NSImage.SymbolConfiguration(pointSize:
  14, weight: .regular)` (tunable).

### Symbol names

- gauge: `gauge.with.dots.needle.50percent` normally
- chart: `chart.bar` normally

These are easy to tune later; the design does not depend on the exact glyph.

## Warning cue (≥ 85%)

The existing notification logic and its 5pt hysteresis (`main.swift:412–419`)
are **unchanged**. This covers only the visual cue on the status item, driven
by the `warn` flag (`pct >= warnPct`):

- **Text modes** (incl. `iconOnly`+`number`): red foreground color, exactly as
  today.
- **Icon glyph modes** (`gauge`, `chart`): swap to a filled / heavier variant
  **and** tint red via `button.contentTintColor = .systemRed`. When not
  warning, `contentTintColor = nil` so the template glyph stays adaptive.
  - gauge warning variant: `gauge.with.dots.needle.100percent`
  - chart warning variant: `chart.bar.fill`

## Menu

Built in `menuNeedsUpdate(_:)` alongside the rest of the menu, inserted before
"Open Activity Monitor" (`main.swift:303`). Pattern mirrors the existing
"Start at Login" toggle (`main.swift:306`): read current setting to set
checkmark state, action writes the setting and re-renders.

- **"Display"** submenu:
  - 4-item radio group for `displayMode`. Active mode shows `.state = .on`.
    Labels: `Count / Total (%)`, `Count / Total`, `Percent`, `Icon only`.
  - When `displayMode == iconOnly`, a nested **"Icon style"** submenu with a
    3-item radio group for `iconStyle` (`Gauge`, `Chart`, `Number`).
- Each item: `target = self`, an `@objc` action that writes the UserDefaults
  key (via the enum) and calls `renderStatusItem(...)` with `latestCount` /
  `limit`. Distinguish which value was chosen via `representedObject`.

## Error / initial states

- The `applicationDidFinishLaunching` placeholder (`"…"`) and the `ps?` error
  state (`main.swift:392`) remain text regardless of mode — they are not
  normal renders. (Optional: render the initial placeholder via
  `renderStatusItem` if counts are already available; not required.)

## Out of scope

- No new dependencies; no Settings/Preferences window — the menu is the UI.
- No change to polling cadence, sparkline, crash-loop detector, or top
  spawners.
