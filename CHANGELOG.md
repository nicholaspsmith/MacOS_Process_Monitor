# Changelog

Every push to `main` is a release. Add a `## [X.Y.Z] - YYYY-MM-DD` section at
the top (minor for features, patch for fixes); GitHub tags it and publishes
the section as the release notes. Versions follow [Semantic
Versioning](https://semver.org/).

## [1.0.1] - 2026-09-23

- chore: regenerate the menu-bar icon image

## [1.0.0] - 2026-09-20

- LICENSE: name the copyright holder above the MPL text
- License: Mozilla Public License 2.0
- docs: document the --login flag
- feat: --login on|off|status from the command line
- docs: Curtain is now Barn
- docs: Apollo Monitor described without the vendor name
- docs: the character menu-bar icon, rendered from code, and what its states mean
- docs: octopus mode comment — four green arms to eight red ones
- docs: octopus mode comment — two green arms to eight red ones
- feat: octopus mode grows and heats from a green squid to eight red arms
- fix: octopus uses its own quarter-step palette
- feat: octopus display mode that fills with the process fraction
- feat: app icon from the Menubarn mascot
- docs: mention the Menubarn widget library
- docs: why a standalone app beats a SwiftBar plugin
- docs: add the Menubarn mascot to the README
- Advertise the menu-bar suite, and add a menu screenshot
- feat: yield the status item during a curtain peek
- Run the ps poll off the main thread so it can't freeze the menu
- docs: document Start at Login options in the README
- docs: note StatusItemKit retrofit + ProcessMonitorCore
- feat: retrofit app onto StatusItemKit
- feat: ProcessMonitorCore — RespawnDetector with churn-ratio gate
- feat: ProcessMonitorCore — CountHistory
- feat: ProcessMonitorCore — topSpawners
- feat: ProcessMonitorCore — parseProcs + ProcRec
- docs: add ProcessMonitor → StatusItemKit retrofit plan
- docs: add menu-bar display modes + severity colours to README
- Update spec to match shipped design (flat menu, 4 colored data-driven icons)
- Update CLAUDE.md for flat menu and colored data-driven icons
- Make data-driven icons bolder and color-coded by severity
- Add filled-arc gauge and filled-wedge pie as icon options
- Replace static icon symbols with data-driven gauge/pie; flatten Display menu
- Revise spec: data-driven gauge/pie icons, flat menu, drop Number
- Fall back to text if status-bar SF Symbol fails to load
- Document customizable menu bar display in CLAUDE.md
- Add Display submenu for menu bar mode and icon style
- Make icon render explicitly image-only to avoid stray title spacing
- Extract status-item rendering into renderStatusItem
- Make storageKey private in settings enums
- Add DisplayMode/IconStyle settings enums
- Add implementation plan for customizable menu bar display
- Add design spec for customizable menu bar display
- Add CLAUDE.md for future agents
- Size sparkline label by direct text measurement
- Add right padding to sparkline so the last bar isn't clipped
- Fix invisible sparkline: use explicit frames, not constraints
- Sparkline as a view-based menu item — narrower dropdown
- Start at Login, process detail window, narrower menu
- Tighten respawn detector: peak-aware ratio + exclude list
- Sparkline, top spawners, and respawn-loop detector
- Red status text past threshold; drop Refresh now
- Add 'Open Activity Monitor' menu item
- Initial commit: menu bar process monitor
