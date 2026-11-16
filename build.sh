#!/bin/bash
# ./build.sh           build + đóng gói build/Roost.app (+ build/roost-hook)
# ./build.sh run       build rồi chạy bản build/ (dev)
# ./build.sh install   build, cài vào /Applications/Roost.app rồi mở (gỡ /Applications/Notch.app cũ)
# Target Swift vẫn tên Notch / notch-hook; file trong bundle đổi tên thành Roost / roost-hook.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Notch Local Signing"   # tên chứng chỉ trong keychain (giữ nguyên), tạo 1 lần bằng scripts/make-signing-cert.sh

swift build -c release

APP=build/Roost.app
rm -rf "$APP" build/Notch.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Notch "$APP/Contents/MacOS/Roost"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Font pixel VT323 (SIL OFL 1.1) cho giao diện Pixel 8-bit.
cp Resources/VT323-Regular.ttf Resources/OFL-VT323.txt "$APP/Contents/Resources/"
# Giao diện Van Gogh: nền tranh + hoạ sĩ chibi (ảnh tạo bằng AI).
cp Resources/VanGogh/vangogh-panel.jpg Resources/VanGogh/vangogh-painter.png "$APP/Contents/Resources/"
# Hook cho Claude Code: 1 bản trong bundle (/Applications/Roost.app/Contents/MacOS/roost-hook) và 1 bản ở build/.
# build/notch-hook: cùng binary (nối socket mới), giữ tạm cho settings Claude cũ còn trỏ tới đường dẫn này.
cp .build/release/notch-hook "$APP/Contents/MacOS/roost-hook"
cp .build/release/notch-hook build/roost-hook
cp .build/release/notch-hook build/notch-hook

# mediaremote-adapter (BSD-3, Vendor/MediaRemoteAdapter): đọc "đang phát" của mọi app qua MediaRemote
# bằng /usr/bin/perl. Build framework bằng clang (không cần CMake), chỉ build lại khi mã nguồn đổi.
MRA_SRC=Vendor/MediaRemoteAdapter
MRA_FW=.build/mediaremote/MediaRemoteAdapter.framework
MRA_BIN="$MRA_FW/Versions/A/MediaRemoteAdapter"
if [ ! -f "$MRA_BIN" ] || [ -n "$(find "$MRA_SRC/src" "$MRA_SRC/include" -newer "$MRA_BIN" -print -quit)" ]; then
  rm -rf "$MRA_FW"
  mkdir -p "$MRA_FW/Versions/A/Resources"
  clang -dynamiclib -fobjc-arc -fvisibility=default -O2 -mmacosx-version-min=14.0 \
    -I "$MRA_SRC/include" -I "$MRA_SRC/src" \
    "$MRA_SRC"/src/adapter/*.m "$MRA_SRC"/src/private/*.m "$MRA_SRC"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO -framework CoreServices \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$MRA_BIN"
  cat > "$MRA_FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key><string>io.github.letoan1.roost.MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.7.7</string>
  <key>CFBundleVersion</key><string>0.7.7</string>
</dict></plist>
PLIST
  ln -sfn A "$MRA_FW/Versions/Current"
  ln -sfn Versions/Current/MediaRemoteAdapter "$MRA_FW/MediaRemoteAdapter"
  ln -sfn Versions/Current/Resources "$MRA_FW/Resources"
fi
mkdir -p "$APP/Contents/Frameworks"
cp -R "$MRA_FW" "$APP/Contents/Frameworks/"
cp "$MRA_SRC/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote-adapter.pl"
cp "$MRA_SRC/LICENSE" "$APP/Contents/Resources/LICENSE-mediaremote-adapter.txt"

# Sparkle (MIT): tự cập nhật. SwiftPM tải framework universal dựng sẵn vào .build/artifacts.
SPARKLE_FW=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/LICENSE-Sparkle.txt"

# Mở khoá bằng khuôn mặt (Packages/FaceUnlockKit, port từ Glance — MIT): model ArcFace (InsightFace,
# chỉ dùng phi thương mại) để nguyên thư mục, app tự compile lúc chạy; kèm NOTICE + giấy phép.
FUK=Packages/FaceUnlockKit
cp -R "$FUK/Sources/FaceUnlockKit/Resources/ArcFaceModel" "$APP/Contents/Resources/ArcFaceModel"
mkdir -p "$APP/Contents/Resources/FaceUnlockKit"
cp "$FUK/NOTICE.md" "$APP/Contents/Resources/FaceUnlockKit/"
cp -R "$FUK/LICENSES" "$APP/Contents/Resources/FaceUnlockKit/"

# Ký bằng chứng chỉ cố định → macOS giữ quyền (Spotify, Lịch) qua các lần build.
# Không có chứng chỉ thì ký ad-hoc: chạy được nhưng mỗi lần build sẽ bị hỏi lại quyền.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "⚠️  Chưa có chứng chỉ \"$IDENTITY\" → ký ad-hoc. Chạy scripts/make-signing-cert.sh một lần."
fi
codesign --force --sign "$SIGN" "$APP/Contents/MacOS/roost-hook"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
# Sparkle có Autoupdate, Updater.app và XPC bên trong: ký cả cây.
codesign --force --deep --sign "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN" "$APP"
codesign --force --sign "$SIGN" build/roost-hook
codesign --force --sign "$SIGN" build/notch-hook
echo "→ $APP, build/roost-hook, build/notch-hook (ký: $SIGN)"

# Dừng cả bản cũ (Notch) lẫn mới (Roost); app tự tắt stream MediaRemote khi nhận SIGTERM,
# dọn thêm stream mồ côi của 2 đường dẫn cài đặt cho chắc.
stop_running() {
  pkill -x Notch || true
  pkill -x Roost || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Notch >/dev/null || pgrep -x Roost >/dev/null || break
    sleep 0.2
  done
  pkill -f "/Applications/(Notch|Roost)\.app/Contents/Resources/mediaremote-adapter\.pl" || true
}

case "${1:-}" in
  run)
    stop_running
    open "$APP"
    ;;
  install)
    stop_running
    rm -rf /Applications/Roost.app
    cp -R "$APP" /Applications/Roost.app
    # Bản mới đã nằm chỗ → gỡ app cũ tên Notch (đúng đường dẫn này thôi).
    if [ -d /Applications/Roost.app/Contents/MacOS ] && [ -d /Applications/Notch.app ]; then
      rm -rf /Applications/Notch.app
      echo "→ đã gỡ /Applications/Notch.app cũ"
    fi
    # Bỏ bản trong build/ để Spotlight/Launchpad chỉ còn 1 "Roost".
    rm -rf "$APP"
    echo "→ đã cài /Applications/Roost.app"
    open /Applications/Roost.app
    ;;
esac
