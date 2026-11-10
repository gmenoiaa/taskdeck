#!/bin/bash
# Regenerates Resources/AppIcon.icns from the drawing in scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET" Resources
swift scripts/make-icon.swift "$TMP/icon.png"

for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon.png" Resources/AppIcon.png
rm -rf "$TMP"
echo "OK: Resources/AppIcon.icns"
