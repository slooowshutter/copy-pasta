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
# Auto-paste needs Accessibility permission, which macOS ties to the signature. An
# ad-hoc signature changes every build, so the grant is lost on each rebuild; signing
# with a stable certificate (README › Accessibility permission) keeps it.
IDENTITY="${PASTEY_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Note: ad-hoc signed, so macOS forgets Pastey's Accessibility permission on every"
    echo "      rebuild. Set PASTEY_SIGN_IDENTITY to keep it (see README)."
fi

if [[ "${1:-}" == "run" ]]; then
    pkill -x Pastey 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched"
fi
