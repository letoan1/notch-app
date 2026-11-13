<p align="center">
  <img src="docs/hero.svg" alt="Notch — biến tai thỏ MacBook thành trung tâm điều khiển" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/Xcode-kh%C3%B4ng%20c%E1%BA%A7n-8A46D6" alt="Không cần Xcode">
  <img src="https://img.shields.io/badge/CPU-~0.5%25%20khi%20thu%20g%E1%BB%8Dn-30D158" alt="CPU ~0.5%">
  <img src="https://img.shields.io/badge/Claude%20Code-hook-D97757" alt="Claude Code hook">
</p>

<p align="center"><b>Rê chuột lên notch</b> → nhạc, lịch, khay file, gương camera và cả Claude Code hiện ngay ở mép trên màn hình.<br>
Không đổi Desktop, không mở thêm cửa sổ.</p>

<table>
  <tr>
    <td width="50%"><img src="docs/card-claude.svg" alt="Duyệt lệnh Claude ngay trên notch"></td>
    <td width="50%"><img src="docs/card-question.svg" alt="Claude hỏi, trả lời tại chỗ"></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/card-tray.svg" alt="Khay kéo thả file"></td>
    <td width="50%"><img src="docs/card-glance.svg" alt="Báo pin và sóng nhạc khi thu gọn"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="docs/card-mirror.svg" alt="Soi gương camera và đèn viền trước khi họp"></td>
  </tr>
</table>

App viết bằng SwiftUI + AppKit, build bằng Swift Package Manager, **không cần Xcode** (chỉ cần Command Line Tools).

## Tính năng

- **Nhạc**: bài đang phát của Spotify / Apple Music (ảnh bìa, tiến trình, ⏮ ⏯ ⏭); hai cánh notch hiện ảnh bìa + sóng nhạc khi thu gọn. Bấm ảnh bìa để mở app nhạc.
- **Lịch**: dải 7 ngày, chuyển tuần bằng ‹ › / vuốt trackpad; sự kiện của ngày đang chọn, nút vào Google Meet / Zoom / Teams.
- **Khay**: kéo file lên notch để cất tạm, kéo ra để thả vào app khác; icon tài liệu tô màu theo loại file, badge số file trên tab.
- **Gương camera** 📷: soi webcam ngay trên notch trước khi họp (lật kiểu gương / như người khác thấy), kèm cuộc họp sắp tới và nút vào Meet. Camera chỉ chạy khi đang mở tab, không ghi hay lưu hình.
- **Đèn viền**: viền trắng ấm quanh mép màn hình rọi sáng mặt khi gọi video trong phòng tối; 3 mức Dịu / Vừa / Mạnh, không chặn chuột, vẫn sáng khi notch thu gọn.
- **Báo pin**: cắm sạc thì notch hiện % pin vài giây.
- **Claude Code**: hiện yêu cầu xin quyền (Cho phép / Từ chối / Luôn cho phép) và câu hỏi của Claude (chọn đáp án hoặc gõ "Khác…") ngay trên notch, qua hook `PermissionRequest`.

## Build & cài

```bash
scripts/make-signing-cert.sh   # 1 lần: chứng chỉ ký code tự ký trong login keychain
./build.sh install             # build, ký, cài vào /Applications/Notch.app rồi mở
```

Ký bằng chứng chỉ cố định để macOS giữ các quyền đã cấp (điều khiển Spotify, đọc Lịch, camera) qua các lần build. Không có chứng chỉ thì `build.sh` ký ad-hoc và macOS sẽ hỏi lại quyền sau mỗi lần build.

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
