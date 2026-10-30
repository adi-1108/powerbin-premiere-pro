#!/usr/bin/env bash
# Regenerate the YouTube thumbnails (1280x720) from assets/branding/PowerBinIcon-1024.png.
#
# Renders at 2x through headless Chrome and downsamples, so the type stays crisp.
# Edit the HEADLINES below and re-run. No dependencies beyond Chrome + sips.
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT=assets/branding/youtube
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME" >&2; exit 1; }

python3 "$OUT/build_html.py"
for v in a b c; do
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1280,720 --screenshot="$OUT/_tmp@2x.png" "file://$PWD/$OUT/_thumb-$v.html" 2>/dev/null
  sips -z 720 1280 "$OUT/_tmp@2x.png" --out "$OUT/powerbin-yt-$v.png" >/dev/null
  echo "  built $OUT/powerbin-yt-$v.png"
done
rm -f "$OUT"/_tmp@2x.png "$OUT"/_thumb-*.html
