#!/usr/bin/env bash
# Regenerate Resources/PowerBin.icns from the vector source.
#
# The icon is macOS Big Sur geometry: 1024 canvas, 824x824 body, continuous-curvature
# squircle. Every size is rendered from the SVG, never upscaled from a raster — which is
# why the source of truth is assets/branding/PowerBinIcon.svg and not a PNG.
#
# Needs librsvg:  brew install librsvg
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="assets/branding/PowerBinIcon.svg"
ICNS="Resources/PowerBin.icns"

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }
[ -f "$SVG" ] || { echo "missing $SVG" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ICONSET="$STAGE/PowerBin.iconset"
mkdir -p "$ICONSET"

echo "==> rendering iconset from $SVG"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" \
            "512:icon_512x512" "1024:icon_512x512@2x"; do
  rsvg-convert -w "${spec%%:*}" -h "${spec%%:*}" "$SVG" -o "$ICONSET/${spec##*:}.png"
done

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "    $ICNS ($(du -h "$ICNS" | cut -f1))"

echo
echo "done. rebuild the app to pick up the icon: CONFIG=release bash Scripts/build-dmg.sh"
