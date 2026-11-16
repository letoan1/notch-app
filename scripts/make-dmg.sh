#!/bin/bash
# Đóng gói Roost thành file .dmg để gắn lên GitHub Release (chưa ký Developer ID, chưa notarize).
#   scripts/make-dmg.sh            → dist/Roost-<phiên bản>.dmg (universal: Apple silicon + Intel)
#   scripts/make-dmg.sh --arm64    → chỉ bản Apple silicon (build nhanh hơn)
# App trong .dmg được ký ad-hoc. Người dùng mở lần đầu sẽ gặp cảnh báo Gatekeeper,
# cách mở có trong "Hướng dẫn mở Roost.html" đi kèm và docs/INSTALL.md.
set -euo pipefail
cd "$(dirname "$0")/.."

ARM_ONLY=0; [ "${1:-}" = "--arm64" ] && ARM_ONLY=1
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP=build/Roost.app
OUT=dist
DMG="$OUT/Roost-$VERSION.dmg"

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

# Ký ad-hoc từ trong ra ngoài (không mang chứng chỉ tự ký của máy build đi phát hành).
codesign --force --sign - "$APP/Contents/MacOS/roost-hook"
codesign --force --sign - "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/Roost"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Roost.app"
ln -s /Applications "$STAGE/Applications"
cp "scripts/dmg/Hướng dẫn mở Roost.html" "$STAGE/"

mkdir -p "$OUT"
rm -f "$DMG"
hdiutil create -volname "Roost $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
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
