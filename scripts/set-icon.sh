#!/bin/bash
# Đổi icon app bằng ảnh của bạn rồi cài lại: scripts/set-icon.sh ~/Downloads/anh.png
# Muốn về icon mặc định: scripts/set-icon.sh --default
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 1 ]] || { echo "Dùng: scripts/set-icon.sh <đường dẫn ảnh> | --default"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [[ "$1" == "--default" ]]; then
  swiftc -O scripts/icon-from-image.swift -o "$TMP/mk" 2>/dev/null
  "$TMP/mk" Resources/AppIcon-source.png "$TMP/icon.png"
else
  [[ -f "$1" ]] || { echo "Không thấy file: $1"; exit 1; }
  swiftc -O scripts/icon-from-image.swift -o "$TMP/mk" 2>/dev/null
  "$TMP/mk" "$1" "$TMP/icon.png"
fi

mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "→ Resources/AppIcon.icns"

./build.sh install
# Dock/Launchpad cache icon: chạm bundle để Finder đọc lại.
touch /Applications/Roost.app
