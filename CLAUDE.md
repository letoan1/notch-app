# CLAUDE.md

Roost: app notch cho macOS (SwiftUI + AppKit), build không cần Xcode. Đọc file này trước khi sửa code.

## Build và chạy

- `./build.sh install`: build release, ký bằng chứng chỉ tự ký "Roost Release Signing" (không có thì "Notch Local Signing"), cài vào `/Applications/Roost.app` rồi mở lại. Build release mất 5–7 phút (cả module biên dịch một lần).
- `scripts/make-dmg.sh`: đóng gói `dist/Roost-<ver>.dmg` universal (arm64 + x86_64), ký bằng "Roost Release Signing" (không bao giờ ad-hoc: ad-hoc làm người dùng mất quyền sau mỗi bản cập nhật), chưa notarize. Phiên bản lấy từ `CFBundleShortVersionString` trong `Info.plist`.
- `scripts/bump-cask.sh`: sau khi đăng GitHub Release, sửa version + sha256 trong cask Homebrew (`../homebrew-tap`, repo `letoan1/homebrew-tap`, push qua SSH) để `brew install --cask letoan1/tap/roost` lấy bản mới.
- `scripts/demo-claude.sh [--question]`: gửi yêu cầu Claude giả lên notch để thử thẻ xin quyền / câu hỏi.
- Chỉ có Command Line Tools, SDK macOS 27. Không có `xcrun metal`, không có plugin macro của Xcode.

## Quy tắc code

- **Không dùng macro** `@State`, `@Observable`, `@Namespace`: SDK biến chúng thành macro mà plugin chỉ có trong Xcode. Dùng `State(initialValue:)` + `.wrappedValue`, `ObservableObject` + `@Published`.
- Comment ngắn; giải thích dài để ở docs.
- Chuỗi giao diện luôn song ngữ qua `L("tiếng Việt", "English")`, viết tự nhiên (không gạch ngang dài, không chuỗi "·").
- CPU khi notch thu gọn phải ~0%: không timer chạy liên tục, dùng sự kiện (IOKit, CoreAudio listener, FSEvents, NWPathMonitor), animation bằng Core Animation. Đo bằng `top -pid` lúc máy rảnh.
- View ẩn mà còn sống vẫn layout liên tục: cửa sổ phụ (màn hình khoá, toàn màn hình) phải huỷ `contentView` khi đóng.
- Mỗi giao diện kiểm tra bằng `Theme.isPixel / isCassette / isVanGogh`; sửa cho một theme không được làm lệch theme khác.

## Cấu trúc chính

- `NotchController`: cửa sổ notch theo từng màn hình, hover/tick, mở/đóng, peek, thú cưng.
- `NotchView` + `NotchHeader` + `NotchLayout`: notch mở, hàng tab, ô trạng thái, nút Cài đặt, cột nút tròn hai bên (tối đa 3 mỗi bên) (bố cục lưu ở `notch.layout.v1`).
- Theme: `Theme.swift`, `PixelTabs.swift`, `Cassette*.swift`, `VanGogh*.swift` (ảnh trong `Resources/VanGogh`).
- Nhạc: `NowPlaying` (MediaRemote qua `Vendor/MediaRemoteAdapter`, AppleScript dự phòng), `PlayerExtras` (shuffle/repeat, icon app), `Lyrics*` (LRCLIB, chỉ Spotify và Apple Music), `LockScreenMusic` (màn hình khoá, chỉ Spotify và Apple Music).
- Âm thanh: `SoundMixer` (thiết bị, âm lượng tổng/mic, âm lượng từng app bằng process tap; về 100% thì gỡ tap), `SoundViews`.
- Claude Code: `Sources/NotchHook` (binary `roost-hook`, socket `~/Library/Application Support/Roost/claude.sock`), `PermissionCenter`, `PermissionCard`, `QuestionCard`, `ClaudeUsage` + `ClaudeUsageAPI` (đọc access token trong Keychain, KHÔNG đụng refresh token, chỉ gửi tới api.anthropic.com).
- Hệ thống: `NotchAlerts` (thẻ thông báo), `SystemWatchers` (pin, Caps Lock, mạng, Downloads), `KeepAwake`.
- Cài đặt: `SettingsWindow` + `SettingsUI` (sidebar + thẻ), `ClaudeSettingsPane`, `FaceUnlockViews`.
- Mở khoá bằng khuôn mặt: `Packages/FaceUnlockKit` (port từ Glance, MIT; model ArcFace chỉ phi thương mại).

## Khi kiểm tra

- Không chụp màn hình được từ shell: render view ra PNG bằng hook debug tạm (gỡ sau) hoặc nhờ người dùng chụp.
- Trước khi đổi cài đặt để thử: `defaults export io.github.letoan1.roost <file>`; xong phải trả lại đúng như cũ.
- Hỏi trước khi commit / push. Không tự sửa file cài đặt Claude Code của người dùng.
