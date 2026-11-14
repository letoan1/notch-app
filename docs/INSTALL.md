# Cài Roost từ file .dmg

Roost cần macOS 14 trở lên. File .dmg trên trang Releases chạy được trên cả Mac chip Apple lẫn Mac Intel. Máy không có tai thỏ vẫn dùng được, Roost sẽ vẽ một notch giả ở giữa mép trên màn hình.

## 1. Cài

1. Tải `Roost-<phiên bản>.dmg` ở trang [Releases](https://github.com/letoan1/notch-app/releases).
2. Mở file .dmg, kéo **Roost** vào thư mục **Applications**.
3. Đẩy ổ đĩa "Roost" ra (eject) cho gọn.

## 2. Mở lần đầu

Roost là app mã nguồn mở và chưa được ký bằng chứng chỉ Developer ID của Apple (gói 99 USD/năm). Vì vậy lần đầu mở, macOS sẽ chặn với thông báo kiểu *"Apple could not verify "Roost" is free of malware"*. Đây là cảnh báo dành cho mọi app chưa notarize, không có nghĩa app có mã độc. Mã nguồn nằm công khai trong repo này và bạn có thể tự build để đối chiếu.

**Cách 1: qua System Settings (macOS 15 trở lên)**

1. Mở Roost trong Applications. Khi hộp thoại cảnh báo hiện ra, bấm **Done**. Đừng bấm "Move to Trash".
2. Mở **System Settings → Privacy & Security**.
3. Kéo xuống mục **Security**, sẽ có dòng *"Roost" was blocked to protect your Mac*. Bấm **Open Anyway**.
4. Nhập mật khẩu máy, rồi bấm **Open Anyway** thêm một lần nữa.

Việc này chỉ cần làm một lần. Những lần sau Roost mở bình thường.

Trên macOS 14 có cách nhanh hơn: chuột phải vào Roost trong Applications, chọn **Open**, rồi bấm **Open** trong hộp thoại.

**Cách 2: một lệnh Terminal**

```bash
xattr -dr com.apple.quarantine /Applications/Roost.app
```

Lệnh này gỡ dấu "tải từ Internet" mà macOS gắn vào app, sau đó app mở được ngay.

**Kiểm tra file tải về (tuỳ chọn)**

Mỗi bản phát hành có kèm mã SHA-256. So với file bạn tải:

```bash
shasum -a 256 ~/Downloads/Roost-*.dmg
```

## 3. Quyền mà Roost sẽ hỏi

Roost chỉ hỏi quyền khi bạn dùng tới tính năng cần nó. Từ chối thì tính năng đó tắt, phần còn lại vẫn chạy.

| Quyền | Dùng cho |
|---|---|
| Lịch | Hiện cuộc họp sắp tới và nút vào Meet |
| Camera | Tab Gương và mở khoá bằng khuôn mặt |
| Tự động hoá (Spotify, Music) | Điều khiển nhạc khi không đọc được qua MediaRemote |
| Trợ năng | Mở khoá bằng khuôn mặt (gõ mật khẩu giúp bạn) |
| Ghi màn hình và âm thanh hệ thống | Chỉ khi bật "Sóng nhạc theo âm thanh thật" |

Màn hình chào lần đầu sẽ hướng dẫn cấp quyền và cài hook cho Claude Code nếu bạn muốn.

## 4. Cập nhật

Tải file .dmg mới rồi kéo Roost vào Applications, chọn **Replace**. Cài đặt và khay file của bạn được giữ nguyên. Bản mới tải về có thể phải "Open Anyway" thêm một lần.

## 5. Gỡ cài đặt

1. Thoát Roost (bấm nút nguồn trên notch).
2. Xoá `/Applications/Roost.app`.
3. Xoá dữ liệu nếu muốn sạch hẳn:

   ```bash
   rm -rf ~/Library/Application\ Support/Roost
   defaults delete io.github.letoan1.roost
   ```

4. Nếu đã nối Roost với Claude Code: mở file `.claude/settings.json` hoặc `.claude/settings.local.json` của project, xoá các mục hook có đường dẫn `/Applications/Roost.app/Contents/MacOS/roost-hook`.

## Gặp lỗi?

Mở một issue ở [GitHub Issues](https://github.com/letoan1/notch-app/issues), ghi kèm phiên bản macOS, loại máy (chip Apple hay Intel) và ảnh chụp nếu có.
