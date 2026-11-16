#!/bin/bash
# Đóng thư mục đã chuẩn bị thành .dmg có bố cục Finder: ảnh nền, cỡ cửa sổ, vị trí icon.
#   scripts/dmg/layout.sh <thư mục stage> <tên volume> <file .dmg ra>
# Thư mục stage phải có Roost.app, Applications (symlink) và "Hướng dẫn mở Roost.html".
# Toạ độ khớp với background.swift. Cần Finder chạy (osascript), lần đầu macOS hỏi quyền Automation.
set -euo pipefail
STAGE=$1; VOL=$2; OUT=$3
HERE="$(cd "$(dirname "$0")" && pwd)"
GUIDE="Hướng dẫn mở Roost.html"

mkdir -p "$STAGE/.background"
swift "$HERE/background.swift" "$STAGE/.background"
tiffutil -cathidpicheck "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null
rm "$STAGE/.background/bg.png" "$STAGE/.background/bg@2x.png"

RW=$(mktemp -d)/rw.dmg
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
# Volume trùng tên đang mount (bản cũ) sẽ làm Finder nhầm đĩa.
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null || true
DEV=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk '/Apple_HFS/{print $1}')

osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set w to container window
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 840, 588}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 100
    set text size of o to 13
    set background picture of o to file ".background:bg.tiff"
    set position of item "Roost.app" of w to {170, 165}
    set position of item "Applications" of w to {470, 165}
    set position of item "$GUIDE" of w to {320, 345}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

rm -rf "/Volumes/$VOL/.fseventsd"
chmod -Rf go-w "/Volumes/$VOL" 2>/dev/null || true
sync
hdiutil detach "$DEV" >/dev/null
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -rf "$(dirname "$RW")"
