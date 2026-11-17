#!/bin/bash
# Cập nhật cask Homebrew (repo letoan1/homebrew-tap) sau khi đã đăng GitHub Release của bản hiện tại:
#   scripts/bump-cask.sh
# Phiên bản lấy từ Info.plist, sha256 từ dist/Roost-<ver>.dmg.sha256. Repo tap mặc định nằm cạnh notch-app
# (../homebrew-tap), đổi bằng ROOST_TAP=/đường/dẫn.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAP=${ROOST_TAP:-../homebrew-tap}
CASK="$TAP/Casks/roost.rb"
SHA=$(cut -d' ' -f1 "dist/Roost-$VERSION.dmg.sha256")
URL="https://github.com/letoan1/notch-app/releases/download/v$VERSION/Roost-$VERSION.dmg"

# File trên GitHub phải đúng là file vừa đóng gói, không thì brew báo sai checksum với người dùng.
REMOTE=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)
if [ "$REMOTE" != "$SHA" ]; then
  echo "✗ sha256 của $URL ($REMOTE) khác dist ($SHA). Đã đăng release v$VERSION chưa?" >&2; exit 1
fi

git -C "$TAP" pull -q --ff-only
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
grep -q "version \"$VERSION\"" "$CASK" && grep -q "sha256 \"$SHA\"" "$CASK" || { echo "✗ Không sửa được $CASK" >&2; exit 1; }
if git -C "$TAP" diff --quiet; then echo "→ cask đã ở bản $VERSION"; exit 0; fi
git -C "$TAP" commit -qam "roost $VERSION"
git -C "$TAP" push -q
echo "→ cask roost $VERSION đã đẩy lên $(git -C "$TAP" remote get-url origin)"
