#!/bin/bash
# Build ProcessMonitor as an .app bundle in ./build/ProcessMonitor.app.
# Delegates to StatusItemKit's shared make-app.sh (dogfooding the framework's
# builder). Bundling + ad-hoc codesign are required so UNUserNotificationCenter
# delivers notifications — unbundled/unsigned binaries get their requests
# silently dropped by macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh ProcessMonitor
