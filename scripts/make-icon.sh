#!/bin/sh
# Regenerates Resources/AppIcon.icns from Latin Modern in the system TeX.
# Usage: scripts/make-icon.sh [dark|light]   (dark = white on black)
set -e
cd "$(dirname "$0")/.."
export PATH="/Library/TeX/texbin:$PATH"
roman=$(kpsewhich lmroman10-regular.otf)
math=$(kpsewhich latinmodern-math.otf)
tmp=$(mktemp -d)
set="$tmp/AppIcon.iconset"
mkdir -p "$set" Resources
swift scripts/icon.swift "$roman" "$math" "${1:-dark}" "$tmp/icon.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
cp "$tmp/icon.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns"
