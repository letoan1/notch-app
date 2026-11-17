#!/bin/bash
# Đo Roost đang chạy: CPU trung bình theo từng trạng thái notch + bộ nhớ (phys_footprint = cột Memory của Activity Monitor).
#   scripts/bench.sh [giây mỗi trạng thái, mặc định 10]
# Mở/đóng notch bằng DistributedNotificationCenter (notifyutil không tới được app).
set -euo pipefail
SEC=${1:-10}
PID=$(pgrep -x Roost) || { echo "✗ Roost không chạy" >&2; exit 1; }
TOGGLE='ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("io.github.letoan1.roost.toggle", $(), $(), true)'
cs() { ps -o time= -p "$PID" | awk -F'[:.]' '{print ($1*60+$2)*100+$3}'; }          # centi-giây CPU đã dùng
cpu() { local a b; a=$(cs); sleep "$SEC"; b=$(cs); awk -v d=$((b-a)) -v s="$SEC" 'BEGIN{printf "%.1f%%", d/s}'; }
mem() { footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/{print $2, $3; exit}'; }
toggle() { osascript -l JavaScript -e "$TOGGLE" >/dev/null; }

echo "Roost $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Roost.app/Contents/Info.plist), pid $PID, ${SEC}s mỗi trạng thái"
echo "bộ nhớ lúc đầu:      $(mem)"
echo "CPU notch đóng:      $(cpu)"
toggle; sleep 1
echo "CPU notch mở:        $(cpu)"
toggle
echo "CPU ngay sau đóng:   $(cpu)"
echo "CPU sau đó:          $(cpu)"
echo "bộ nhớ lúc cuối:     $(mem)"
