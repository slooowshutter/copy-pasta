#!/bin/bash
# Build Pastey.app from the Swift package. Usage: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/Pastey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Pastey "$APP/Contents/MacOS/Pastey"
cp Info.plist "$APP/Contents/Info.plist"
# ponytail: ad-hoc signature is enough until we need Accessibility (phase 3),
# then switch to a stable self-signed cert so macOS stops forgetting the permission.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "run" ]]; then
    pkill -x Pastey 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched"
fi
