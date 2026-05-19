# MacOS_Process_Monitor

A tiny macOS menu bar app that shows the number of processes owned by the
current user and notifies when the count climbs past 85% of
`kern.maxprocperuid` — the limit that, once hit, causes `fork()` to start
returning `EAGAIN` and breaks terminals, browsers, and most apps.

Mirrors `ps -u $USER | wc -l` exactly so the menu bar number matches what you
see in a shell.

## Build

Requires Xcode command line tools (Swift 5.9+, macOS 13+).

```sh
./scripts/build-app.sh
```

Produces `build/ProcessMonitor.app`.

## Run

```sh
open build/ProcessMonitor.app
```

The icon appears in the menu bar (no Dock icon — `LSUIElement` is set). Click
it for "Refresh now" and "Quit".

On first launch macOS will ask for notification permission. Approve it,
otherwise the threshold alert can't fire.

## Configuration

Tunables live at the top of `Sources/ProcessMonitor/main.swift`:

- `warnPct` — threshold in percent (default `85`)
- `pollSeconds` — refresh interval (default `5`)

Rebuild after changing.

## Start at login (optional)

To launch at login without a LaunchAgent, add `ProcessMonitor.app` under
**System Settings → General → Login Items → Open at Login**.

A LaunchAgent would also work but isn't installed by default — keeping the
launch decision in the user's hands avoids surprise behavior.
