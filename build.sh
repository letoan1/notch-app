#!/bin/bash
# ./build.sh           build + đóng gói build/Notch.app (+ build/notch-hook)
# ./build.sh run       build rồi chạy bản build/ (dev)
# ./build.sh install   build, cài vào /Applications/Notch.app rồi mở
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Notch Local Signing"   # tạo 1 lần bằng scripts/make-signing-cert.sh

swift build -c release

APP=build/Notch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Notch "$APP/Contents/MacOS/Notch"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Font pixel VT323 (SIL OFL 1.1) cho giao diện Pixel 8-bit.
cp Resources/VT323-Regular.ttf Resources/OFL-VT323.txt "$APP/Contents/Resources/"
# Hook cho Claude Code nằm ngoài bundle, đường dẫn cố định để settings trỏ vào.
cp .build/release/notch-hook build/notch-hook

# Ký bằng chứng chỉ cố định → macOS giữ quyền (Spotify, Lịch) qua các lần build.
# Không có chứng chỉ thì ký ad-hoc: chạy được nhưng mỗi lần build sẽ bị hỏi lại quyền.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "⚠️  Chưa có chứng chỉ \"$IDENTITY\" → ký ad-hoc. Chạy scripts/make-signing-cert.sh một lần."
fi
codesign --force --sign "$SIGN" "$APP"
codesign --force --sign "$SIGN" build/notch-hook
echo "→ $APP, build/notch-hook (ký: $SIGN)"

stop_running() {
  pkill -x Notch || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Notch >/dev/null || return 0; sleep 0.2; done
}

case "${1:-}" in
  run)
    stop_running
    open "$APP"
    ;;
  install)
    stop_running
    rm -rf /Applications/Notch.app
    cp -R "$APP" /Applications/Notch.app
    # Bỏ bản trong build/ để Spotlight/Launchpad chỉ còn 1 "Notch".
    rm -rf "$APP"
    echo "→ đã cài /Applications/Notch.app"
    open /Applications/Notch.app
    ;;
esac
