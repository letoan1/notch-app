#!/bin/bash
# Đóng gói Roost thành file .dmg để gắn lên GitHub Release (chưa ký Developer ID, chưa notarize).
#   scripts/make-dmg.sh            → dist/Roost-<phiên bản>.dmg (universal: Apple silicon + Intel)
#   scripts/make-dmg.sh --arm64    → chỉ bản Apple silicon (build nhanh hơn)
# App trong .dmg được ký bằng chứng chỉ tự ký "Roost Release Signing" (tạo 1 lần bằng
# scripts/make-signing-cert.sh "Roost Release Signing", nhớ sao lưu .p12). Ký cố định thì macOS nhận diện
# app theo bundle id + chứng chỉ, nên quyền Trợ năng, Camera, Lịch… còn nguyên qua các bản cập nhật.
# Ký ad-hoc thì mỗi bản có cdhash mới và người dùng mất hết quyền sau mỗi lần cập nhật.
# Chưa có Developer ID nên lần mở đầu vẫn gặp cảnh báo Gatekeeper,
# cách mở có trong "Hướng dẫn mở Roost.html" đi kèm và docs/INSTALL.md.
set -euo pipefail
cd "$(dirname "$0")/.."

ARM_ONLY=0; [ "${1:-}" = "--arm64" ] && ARM_ONLY=1
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP=build/Roost.app
OUT=dist
DMG="$OUT/Roost-$VERSION.dmg"
SIGN="Roost Release Signing"

# Không có chứng chỉ thì dừng, không lùi về ad-hoc: phát hành bản ad-hoc là làm người dùng mất quyền.
if ! security find-identity -p codesigning | grep -q "\"$SIGN\""; then
  echo "✗ Không thấy chứng chỉ \"$SIGN\" trong keychain." >&2
  echo "  Máy phát hành: nhập lại file .p12 đã sao lưu (mở file .p12, nhập vào login keychain)." >&2
  echo "  Chỉ lần đầu tiên mới tạo mới: scripts/make-signing-cert.sh \"$SIGN\"" >&2
  exit 1
fi

echo "→ build bản Apple silicon"
./build.sh >/dev/null

if [ $ARM_ONLY -eq 0 ]; then
  echo "→ build bản Intel"
  swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86 >/dev/null
  lipo -create .build/release/Notch .build-x86/release/Notch -output "$APP/Contents/MacOS/Roost"
  lipo -create .build/release/notch-hook .build-x86/release/notch-hook -output "$APP/Contents/MacOS/roost-hook"
  # mediaremote-adapter: build lại cả 2 kiến trúc trong một lần.
  MRA_SRC=Vendor/MediaRemoteAdapter
  MRA_BIN="$APP/Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"
  clang -dynamiclib -fobjc-arc -fvisibility=default -O2 -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
    -I "$MRA_SRC/include" -I "$MRA_SRC/src" \
    "$MRA_SRC"/src/adapter/*.m "$MRA_SRC"/src/private/*.m "$MRA_SRC"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO -framework CoreServices \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$MRA_BIN"
fi

# Ký từ trong ra ngoài bằng chứng chỉ phát hành.
codesign --force --sign "$SIGN" "$APP/Contents/MacOS/roost-hook"
codesign --force --sign "$SIGN" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --deep --sign "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"
# Designated requirement phải theo chứng chỉ, không phải cdhash (cdhash = quyền mất sau mỗi bản).
if codesign -d -r- "$APP" 2>&1 | grep -q "designated => cdhash"; then
  echo "✗ App vẫn mang designated requirement theo cdhash, không phát hành." >&2; exit 1
fi
lipo -info "$APP/Contents/MacOS/Roost"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Roost.app"
ln -s /Applications "$STAGE/Applications"
cp "scripts/dmg/Hướng dẫn mở Roost.html" "$STAGE/"

mkdir -p "$OUT"
rm -f "$DMG"
# Ảnh nền, cỡ cửa sổ và vị trí icon: xem scripts/dmg/layout.sh.
scripts/dmg/layout.sh "$STAGE" "Roost $VERSION" "$DMG" 2> >(grep -v 'is deprecated' >&2)
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "→ $DMG ($(du -h "$DMG" | cut -f1))"

# Appcast cho Sparkle: ký .dmg bằng khoá EdDSA trong login keychain (tạo một lần bằng
# .build/artifacts/sparkle/Sparkle/bin/generate_keys) rồi ghi dist/appcast.xml.
# Đưa cả .dmg lẫn appcast.xml lên GitHub Release có tag v<phiên bản>; app đọc
# releases/latest/download/appcast.xml. Mỗi bản phải tăng CFBundleVersion, Sparkle so số này.
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
FEED=$(mktemp -d)
cp "$DMG" "$FEED/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/letoan1/notch-app/releases/download/v$VERSION/" \
  -o "$OUT/appcast.xml" "$FEED"
rm -rf "$FEED"
echo "→ $OUT/appcast.xml (bản $VERSION, build $BUILD)"
