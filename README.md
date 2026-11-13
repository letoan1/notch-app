# Notch

App "tai thỏ" cho MacBook có notch: rê chuột vào notch để mở bảng điều khiển nhỏ ở mép trên màn hình. Viết bằng SwiftUI + AppKit, build bằng Swift Package Manager, **không cần Xcode** (chỉ cần Command Line Tools).

## Tính năng

- **Nhạc**: bài đang phát của Spotify / Apple Music (ảnh bìa, tiến trình, ⏮ ⏯ ⏭); hai cánh notch hiện ảnh bìa + sóng nhạc khi thu gọn. Bấm ảnh bìa để mở app nhạc.
- **Lịch**: dải 7 ngày, chuyển tuần bằng ‹ › / vuốt trackpad; sự kiện của ngày đang chọn, nút vào Google Meet / Zoom / Teams.
- **Khay**: kéo file lên notch để cất tạm, kéo ra để thả vào app khác.
- **Báo pin**: cắm sạc thì notch hiện % pin vài giây.
- **Claude Code**: hiện yêu cầu xin quyền (Cho phép / Từ chối / Luôn cho phép) và câu hỏi của Claude (chọn đáp án hoặc gõ "Khác…") ngay trên notch, qua hook `PermissionRequest`.

## Build & cài

```bash
scripts/make-signing-cert.sh   # 1 lần: chứng chỉ ký code tự ký trong login keychain
./build.sh install             # build, ký, cài vào /Applications/Notch.app rồi mở
```

Ký bằng chứng chỉ cố định để macOS giữ các quyền đã cấp (điều khiển Spotify, đọc Lịch) qua các lần build. Không có chứng chỉ thì `build.sh` ký ad-hoc và macOS sẽ hỏi lại quyền sau mỗi lần build.

Lệnh khác: `./build.sh run` (chạy bản trong `build/`), `scripts/set-icon.sh <ảnh>` (đổi icon), `scripts/set-icon.sh --default`.

## Nối với Claude Code

Thêm vào `.claude/settings.local.json` của project (hoặc `~/.claude/settings.json`):

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/đường/dẫn/tới/notch-app/build/notch-hook", "timeout": 110 }] }
    ]
  }
}
```

`notch-hook` gửi yêu cầu sang app qua Unix socket `~/Library/Application Support/Notch/claude.sock` (quyền 0600). App tắt, hết giờ, hoặc bấm "Trả lời trong VS Code" → hook không trả quyết định và Claude Code hỏi như bình thường.

## Ghi chú kỹ thuật

- SDK macOS 27 biến `@State` / `@Namespace` của SwiftUI thành macro mà plugin chỉ có trong Xcode → code dùng `State(initialValue:)` / `Namespace()` tường minh.
- Nhạc đọc qua AppleScript trên queue riêng + distributed notification của Spotify/Music (không dùng private framework MediaRemote).
- Sóng nhạc vẽ bằng Core Animation; hover poll 10Hz khi chuột ở xa, 60Hz khi lại gần — CPU ~0.1–1% khi thu gọn.
