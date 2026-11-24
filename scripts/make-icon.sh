#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns. Run after editing the SVG and commit both.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "rsvg-convert not found: brew install librsvg" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"

for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg -o "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    rsvg-convert -w "$double" -h "$double" Resources/AppIcon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done

# Build into the temp dir first so a failure never leaves a half-written icon in the repo.
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
mv "$WORK/AppIcon.icns" Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
