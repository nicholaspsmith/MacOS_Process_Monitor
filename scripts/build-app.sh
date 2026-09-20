#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Nicholas Smith

# Build ProcessMonitor as an .app bundle in ./build/ProcessMonitor.app.
# Delegates to StatusItemKit's shared make-app.sh (dogfooding the framework's
# builder). Bundling + ad-hoc codesign are required so UNUserNotificationCenter
# delivers notifications — unbundled/unsigned binaries get their requests
# silently dropped by macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh ProcessMonitor
