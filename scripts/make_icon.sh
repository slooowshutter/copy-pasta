#!/bin/bash
# Render Resources/AppIcon.svg into Resources/AppIcon.icns, the app icon build.sh puts in
# CopyPasta.app. Run it after changing the SVG, and commit both files.
#
# The SVG ("Fork Twirl") is drawn on the 1024 px macOS icon grid: an 824 px rounded square
# with its shadow baked in. Each size is rendered from the vector (sharper at 16-64 px than
# scaling one big bitmap down), headlessly with rsvg-convert (`brew install librsvg`).
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/AppIcon.svg"
ICNS="Resources/AppIcon.icns"
command -v rsvg-convert >/dev/null || { echo "error: needs rsvg-convert: brew install librsvg" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"

# iconutil's names: icon_<points>x<points>[@2x].png
for points in 16 32 128 256 512; do
    rsvg-convert -w "$points" -h "$points" "$SVG" -o "$ICONSET/icon_${points}x${points}.png"
    rsvg-convert -w $((points * 2)) -h $((points * 2)) "$SVG" -o "$ICONSET/icon_${points}x${points}@2x.png"
done

iconutil --convert icns --output "$ICNS" "$ICONSET"
echo "Wrote $ICNS"
