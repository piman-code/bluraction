#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
iconset="$(mktemp -d "$repo_root/.build/AppIcon.XXXXXX")/AppIcon.iconset"
mkdir -p "$iconset"
trap 'rm -rf "$(dirname "$iconset")"' EXIT
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$repo_root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$repo_root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
candidate="$(dirname "$iconset")/AppIcon.icns"
if ! iconutil -c icns "$iconset" -o "$candidate" || [[ ! -s "$candidate" ]]; then
    # Some Command Line Tools installations reject a valid iconset. Pillow can
    # package the same PNG sizes into an ICNS file on those systems.
    python3 - "$repo_root/Resources/AppIcon.png" "$candidate" <<'PY'
import sys
from PIL import Image

with Image.open(sys.argv[1]) as source:
    source.convert("RGBA").save(sys.argv[2], format="ICNS")
PY
fi
iconutil -c iconset "$candidate" -o "$(dirname "$iconset")/AppIcon-readback.iconset"
cp "$candidate" "$repo_root/Resources/AppIcon.icns"
