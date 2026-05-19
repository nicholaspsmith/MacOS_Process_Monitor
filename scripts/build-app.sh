#!/bin/bash
# Build ProcessMonitor as an .app bundle in ./build/ProcessMonitor.app.
# Bundling is required so UNUserNotificationCenter can deliver notifications —
# unbundled Swift binaries don't have a bundle identifier and macOS rejects
# their notification requests silently.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ProcessMonitor"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)/${APP_NAME}
if [ ! -x "$BIN_PATH" ]; then
    echo "Build did not produce executable at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

# Ad-hoc sign so notifications/launch services treat this as a stable identity.
codesign --force --sign - "${APP_BUNDLE}" >/dev/null

echo "==> Built ${APP_BUNDLE}"
echo "Launch with: open ${APP_BUNDLE}"
