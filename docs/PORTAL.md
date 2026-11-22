# Portal: gửi từ iPhone sang Mac

iPhone hất ảnh, video, file hoặc clipboard về mép trái. Trên màn hình Mac có con trỏ, mép phải sáng lên đúng độ cao ngón tay ngay lúc còn đang kéo, rồi một máy bay giấy gấp từ chính tấm ảnh lao ra từ mép phải, lượn, đáp, chờ nhận xong thì mở từng nếp thành tấm ảnh, gấp lại và bay vào notch, nằm trong khay. File lưu vào Downloads (đổi được trong Cài đặt > Portal).

Không có server nào ở giữa: Mac mở một cổng TCP trong mạng cục bộ và quảng bá Bonjour `_roost-portal._tcp`, bật peer-to-peer nên hai máy không chung Wi-Fi vẫn thấy nhau qua AWDL (Wi-Fi trực tiếp, như AirDrop).

## Mã nguồn

- `Sources/Notch/Portal.swift`: `PortalServer` (NWListener, cổng 52525, không được thì cổng bất kỳ), `PortalSession` (một yêu cầu HTTP mỗi kết nối), `PortalSettings`, thiết bị đã ghép trong Keychain (chỉ lưu SHA-256 của token).
- `Sources/Notch/PortalLanding.swift`: `PortalCenter` (lưu file, clipboard, hỏi ghép), `PortalPairingPanel` (thẻ duyệt dưới notch, tự từ chối sau 60 giây).
- `Sources/Notch/PortalOrigami.swift`: `PortalFlight` (máy bay giấy, SceneKit trong cửa sổ trong suốt, huỷ ngay khi xong), `PortalHover` (mép phải sáng lúc iPhone đang kéo), `OrigamiPaper` (tờ giấy chia mặt nối bản lề, gấp cứng).
- `ios/RoostPortal.xcodeproj`: app iPhone (SwiftUI, Network framework, PhotoKit, SceneKit). Mở bằng Xcode, chạy trên iPhone thật.
- `Sources/Notch/PortalSettingsPane.swift`: trang Cài đặt.
- `scripts/demo-portal.sh`: thử bằng curl, không cần iPhone.

Khi tắt Portal thì không có listener nào. Khi bật mà không ai gửi gì thì chỉ có socket chờ, CPU 0%.

## Giao thức (HTTP/1.1, mỗi kết nối một yêu cầu)

| Yêu cầu | Xác thực | Ghi chú |
| --- | --- | --- |
| `GET /hello` | không | `{"name", "id", "v": 1, "paired"}`. `paired` cho biết token gửi kèm còn hợp lệ không. |
| `POST /pair` | không | Body JSON `{"name": "iPhone của Toàn", "code": "4821"}`. Mac hiện thẻ duyệt (kèm mã nếu có), chờ tối đa 60 giây. Cho phép: `200 {"token", "device", "mac", "macID"}`. Từ chối: 403. Đang có yêu cầu khác hoặc vừa từ chối dưới 10 giây: 429. |
| `POST /send` | có | Body là nội dung file, bắt buộc `Content-Length`. Tên ở `X-Roost-Name` (mã hoá %), đuôi riêng ở `X-Roost-Ext` nếu tên không có đuôi, không có cả hai thì suy từ `Content-Type`. Trả `{"ok": true, "name"}` sau khi file đã lưu xong. |
| `POST /hover` | có | Không body. `X-Roost-Y` (0 đỉnh, 1 đáy), `X-Roost-Near` (0..1, độ gần mép trái), `X-Roost-Phase` (`move`, `fling`, `cancel`). App gửi tối đa ~25 lần/giây khi kéo ảnh. |
| `POST /clipboard` | có | Tối đa 25 MB. `text/*` thành chữ, `image/*` thành ảnh, kiểu khác thì chép đúng kiểu đó. |

Xác thực: `Authorization: Bearer <token>` (hoặc `X-Roost-Token`). Sai token: 401. Có hỗ trợ `Expect: 100-continue`, nên với file lớn Mac từ chối trước khi iPhone kịp gửi body.

Header tuỳ chọn `X-Roost-Y` của `/send`: độ cao ngón tay lúc hất, máy bay giấy ra đúng độ cao đó.

TXT của dịch vụ Bonjour gồm `id`, `port`, `ip` (IPv4 của Mac, cách nhau dấu phẩy). App nối thẳng IP trước, không được mới để Bonjour phân giải: phân giải tên máy ngẫu nhiên `*.local` có lúc treo.

Hiệu ứng bắt đầu ngay khi Mac nhận header, nên video lớn vẫn có cảm giác tức thì; thanh dưới thẻ chạy theo tiến độ.

Bản này chạy HTTP thường trong mạng cục bộ: token không lộ ra Internet nhưng ai bắt gói được trong cùng mạng Wi-Fi thì đọc được. App RoostPortal sẽ chuyển sang TLS với khoá chia sẻ trước (token làm PSK); Phím tắt vẫn dùng HTTP.

## Thử trên chính máy Mac

```bash
scripts/demo-portal.sh pair          # bấm Cho phép trên thẻ dưới notch
scripts/demo-portal.sh send ~/Pictures/*.jpg
scripts/demo-portal.sh clip "Xin chào"
```

## Gửi từ iPhone bằng Phím tắt (trước khi có app)

1. Trên Mac: Cài đặt > Portal > bật "Nhận từ iPhone", rồi bấm "Tạo mã cho Phím tắt". Mã được chép vào clipboard dạng `Bearer …` (Universal Clipboard đưa sang iPhone). Chép luôn "Địa chỉ cho Phím tắt", dạng `http://Ten-May.local:52525`.
2. Trên iPhone, app Phím tắt, tạo phím tắt mới tên "Gửi sang Mac":
   - Bấm (i), bật "Hiển thị trong Bảng chia sẻ", loại nhận: Ảnh, Phương tiện, Tệp.
   - Thêm "Lặp lại với Mỗi mục" trong "Đầu vào Phím tắt".
   - Trong vòng lặp thêm "Lấy nội dung của URL": URL là `http://Ten-May.local:52525/send`, Phương thức POST, Nội dung yêu cầu: Tệp, chọn "Mục lặp lại".
   - Mở "Tiêu đề" (Headers), thêm `Authorization` = mã vừa dán, `X-Roost-Name` = "Mục lặp lại" chọn thuộc tính Tên, `X-Roost-Ext` = "Mục lặp lại" chọn thuộc tính Phần mở rộng tệp.
3. Gửi clipboard: phím tắt khác gồm "Lấy bảng tạm" rồi "Lấy nội dung của URL" tới `/clipboard`, POST, Nội dung: Tệp là Bảng tạm, header `Authorization` như trên.
4. Lần chạy đầu iOS hỏi quyền kết nối thiết bị trong mạng cục bộ: cho phép.

Phím tắt chỉ chạy khi iPhone và Mac cùng mạng Wi-Fi (Phím tắt không dùng được AWDL). App RoostPortal thì không cần chung Wi-Fi.

## Lỗi hay gặp

- Phím tắt báo không kết nối được: kiểm tra Cài đặt > Portal ghi "Đang chờ iPhone"; Tường lửa macOS (Cài đặt hệ thống > Mạng > Tường lửa) phải cho Roost nhận kết nối đến; thử địa chỉ IP của Mac thay cho `.local`.
- 401: mã đã bị gỡ trong Cài đặt, tạo mã mới.
- Tên Mac trong `.local` lấy từ Cài đặt hệ thống > Chung > Chia sẻ > Tên máy chủ cục bộ.
