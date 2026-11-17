# Roost: checklist kỹ thuật trước khi phát hành

Ngày đo: 2026-11-14. Bản đo là working tree chưa commit, nằm trên commit `327a7e5`. Bản cài: `/Applications/Roost.app` (bundle id `io.github.letoan1.roost`).

Máy đo: MacBook Air M2 (Mac14,2), macOS 27.2.1, màn hình có notch. Trong lúc đo, máy lúc chạy pin (22%) lúc cắm sạc (34%). Nhạc phát trong trình duyệt Dia ở nửa đầu buổi đo, sau đó người dùng tạm dừng. Tôi không bật hay tắt nhạc của người dùng.

## Tóm tắt

| Hạng mục | Trạng thái | Kết quả đo / bằng chứng | Còn lại |
|---|---|---|---|
| 1. CPU | ⚠️ | Thu gọn: 0,00-0,01%. Mở tab Media lúc có nhạc: 9,8% trước khi sửa. Mở tab Khay: 8,0% trước sửa, 1,7% sau sửa. Gương (camera bật): 9,0%. Cài đặt mở: 0,00%. Tiến trình perl: 0,00-0,08% | Chưa đo lại tab Media lúc có nhạc sau khi sửa (người dùng đã dừng nhạc). Vòng poll chuột 60 Hz khi notch mở tốn khoảng 1,5-1,7% |
| 2. Bộ nhớ | ⚠️ | Lúc mở app 29-30 MB footprint. 20 lần mở/đóng notch: 42 → 42 MB. 3 lần mở gương: 42 → 77 → 82 → 93 MB. Cài đặt: 30 → 47 MB rồi đứng yên. `leaks` trước sửa: 169 leak (12,7 KB), toàn là `HookConnection`. Sau sửa: 0 leak | Phiên camera giữ lại 35-50 MB sau khi đóng gương |
| 3. Pin / hoạt động nền | ✅ | Đã liệt kê mọi timer, observer, tiến trình con. Sửa 3 chỗ chạy nền không cần thiết | Timer thú cưng vẫn chạy khi tắt thú cưng (30 s và 20-40 s, gần như không tốn) |
| 4. Camera | ✅ | Đèn camera bật 1,2 s sau `startRunning`, tắt 0,3 s sau khi đóng tab. 3/3 lần đều tắt. Vision chỉ chạy khi gương mở | Không có |
| 5. Quyền được xin | ✅ | Lúc mở app không có yêu cầu quyền nào hiện hộp thoại (log TCC chỉ có preflight). Trợ năng chỉ xin khi bấm nút trong mục Khuôn mặt | Automation (Spotify/Music) vẫn có thể tự hỏi khi MediaRemote không có bài mà Spotify/Music đang mở |
| 6. Khi bị từ chối quyền | ⚠️ | Lịch, Camera gương, Automation (màn chào) có nút mở Cài đặt hệ thống. Đã thêm cho Camera và Trợ năng ở mục Khuôn mặt, và cho âm thanh hệ thống | Automation bị từ chối: notch không báo gì |
| 7. Lưu trạng thái | ⚠️ | Cài đặt, khay, giao diện, thú cưng, khuôn mặt, quyền "Luôn cho phép" của Claude đều còn sau khi khởi động lại | Lịch sử Claude và tab đang mở không được lưu. Khay có thể tự bỏ file khi tạm thời không đọc được file |
| 8. Hook Claude khi app chết | ✅ | `test_hook.py --real`: 16/16 PASS. Sau `kill -9`, hook thoát trong 0,015 s, mở lại app thì socket được tạo mới và nhận yêu cầu | Không có |
| 9. Phân phối | ❌ | Ký bằng chứng chỉ tự tạo "Notch Local Signing", không có Team ID, không hardened runtime, không entitlement, chưa notarize, Gatekeeper từ chối (`spctl`: rejected) | Cần Developer ID, hardened runtime, entitlement, notarize, cơ chế cập nhật. Giấy phép model ArcFace chỉ cho dùng phi thương mại |
| 10. Tương thích | ⚠️ | Mục tiêu tối thiểu macOS 14.0 ở cả Package.swift, Info.plist và binary. Process tap được bọc `#available(macOS 14.2, *)`. Chỉ có arm64 | Chưa chạy thử trên macOS 14, 15, 26, máy Intel, máy không có notch |

## Các sửa đổi trong lần audit này

| File | Sửa gì | Lý do |
|---|---|---|
| `Sources/Notch/PermissionCenter.swift` | `HookConnection.finish()` bỏ `onRequest`, `onClose`, `source` sau khi đóng | Hai closure giữ chính kết nối, mỗi yêu cầu của Claude rò khoảng 0,5 KB. `leaks` thấy 27 kết nối bị giữ lại |
| `Sources/Notch/ScreenshotWatcher.swift`, `NotchController.swift` | Chỉ chạy khi bật "Ảnh chụp vào khay" và tab Khay. Thêm `setEnabled`/`stop` | Trước đây timer đọc clipboard 2 lần/giây và truy vấn Spotlight luôn chạy, kể cả khi tính năng đang tắt (máy đo đang tắt) |
| `Sources/Notch/NowPlaying.swift` | Không chạy AppleScript lúc mở app khi có adapter. Timer poll 3 s chỉ chạy khi adapter MediaRemote chết | Tránh gửi Apple event (và hộp thoại xin quyền) ngay lúc khởi động. Tránh đánh thức Spotify mỗi 3 s khi không có gì phát |
| `Sources/Notch/NotchView.swift` | Thanh tiến độ nhạc: 30 → 10 khung/giây | Mẫu `sample` cho thấy phần lớn 9,8% CPU là SwiftUI dựng lại cả notch theo `TimelineView` |
| `Sources/Notch/TrayView.swift` | Viền nét đứt của ô thả file chỉ chạy khi đang kéo file vào | Animation `repeatForever` của `dashPhase` làm SwiftUI vẽ lại mỗi khung hình: 8,0% CPU khi mở tab Khay. Sau sửa còn 0,04% (không tính poll chuột). Đây là thay đổi về hình, xem phần "Cần quyết định" |
| `Sources/Notch/CalendarStore.swift` | Timer 60 s có `tolerance = 10` | Cho hệ thống gộp lần thức dậy |
| `Sources/Notch/FaceUnlockViews.swift` | Camera bị từ chối: nút "Mở Cài đặt hệ thống". Nút Trợ năng mở thẳng mục Trợ năng | Trước đây nút "Cấp quyền" không làm gì khi camera đã bị từ chối. Hộp thoại Trợ năng của macOS chỉ hiện lần đầu |
| `Sources/Notch/SettingsWindow.swift` | Khi bật "Sóng nhạc theo âm thanh thật": dòng gợi ý và nút mở `Privacy_AudioCapture` | Không có API kiểm tra quyền này, bị từ chối thì sóng lặng lẽ quay về hiệu ứng giả |

Hook debug tạm (đổi tab, đổi giao diện qua distributed notification) đã gỡ trước lần build cuối. `./build.sh install` thành công, app chạy lại, socket có mặt, `leaks` báo 0.

## 1. CPU

Cách đo: script `measure.sh` gọi `top -l N -s 1 -pid <Roost> -pid <perl> -stats pid,cpu,idlew,power,mem`, bỏ mẫu đầu, lấy trung bình 20-25 mẫu (1 mẫu/giây) sau khi để yên vài giây. Kèm `footprint` và `ps -o rss`. Mở/đóng notch bằng notification `io.github.letoan1.roost.toggle`. Đổi tab, giao diện, thú cưng bằng hook debug tạm. Khi notch mở bằng notification mà chuột đứng yên, vòng poll 60 Hz không chạy. Vì vậy với các trạng thái mở, tôi đo cả hai trường hợp: có poll (giống lúc chuột đang ở trên notch) và không poll.

| Trạng thái | CPU trung bình | CPU cao nhất | Footprint | Ghi chú |
|---|---|---|---|---|
| Thu gọn, nhạc đang phát (trước sửa) | 0,01% | 0,1% | 30 MB | Sóng nhạc là animation Core Animation, chạy ở render server |
| Thu gọn, nhạc đang phát (sau sửa) | 0,00% | 0,0% | 29 MB | |
| Thu gọn, không có nhạc (đã dừng) | 0,00-0,01% | 0,3% | 29-38 MB | Bản build cuối: 0,00% |
| Mở tab Media, có nhạc, có poll (trước sửa) | 9,80% | 11,7% | 43 MB | `sample`: phần lớn là `NSHostingView.layout` do `TimelineView` 30 fps |
| Mở tab Media, có nhạc, có poll (sau sửa 14/11) | 1,5-1,7% | 2,1% | 136-138 MB | Thanh tiến độ chạy bằng Core Animation, chữ thời gian 1 lần/giây. Footprint cao vì vừa mở Gương trước đó |
| Mở tab Media, không nhạc, có poll | 1,49-1,73% | 2,6% | 39-55 MB | Gần như toàn bộ là vòng poll chuột 60 Hz |
| Mở tab Media, không nhạc, không poll | 0,00-0,09% | 1,9% | 36-38 MB | |
| Mở tab Khay, có poll (trước sửa) | 8,02% | 9,2% | 42 MB | Viền nét đứt chạy liên tục |
| Mở tab Khay, có poll (sau sửa) | 1,56-1,73% | 2,0% | 38-55 MB | |
| Mở tab Khay, không poll (sau sửa) | 0,04% | 0,4% | 38 MB | |
| Mở tab Gương, camera bật | 8,97% | 11,9% | 142 MB | AVCapture + preview + Vision tối đa 2 lần/giây |
| Cửa sổ Cài đặt mở (tab Chung) | 0,00% | 0,0% | 47 MB | |
| Thú cưng bật, thu gọn | 0,26% | 5,3% | 51 MB | Đỉnh 5,3% là lúc thú cưng làm một trò (20-40 s/lần) |
| Thú cưng bật, mở Media, có poll | 1,59% | 2,1% | 56 MB | Tắt thú cưng: 1,49% |
| Giao diện Pixel: thu gọn / Media / Khay | 0,00% / 1,56% / 1,56% | 2,0% | 55-56 MB | Có poll |
| Giao diện Cassette: thu gọn / Media | 0,00% / 1,94% | 3,7% | 55-57 MB | Băng cassette cập nhật 1 lần/giây |
| Giao diện Cassette: Khay | không tin cậy | | | Lần đo ra 0,00%, có thể notch chưa mở. Không đo lại |
| Giao diện Mặc định: Media / Khay | 1,55% / 1,7% | 2,4% | 58-59 MB | Có poll |
| "Ảnh chụp vào khay" bật / tắt, thu gọn | 0,01% / 0,00% | 0,2% | 58 MB | Timer 0,5 s rất rẻ, nhưng là 2 lần thức dậy mỗi giây |
| Tiến trình perl (mediaremote stream) | 0,00-0,08% | 1,2% | RSS khoảng 6 MB | Đỉnh lúc đổi bài |

Idle wakeups: cột `IDLEW` của `top` ở chế độ log là bộ đếm cộng dồn, tôi lấy hiệu giữa mẫu cuối và mẫu đầu. Gần như mọi trạng thái ra 0/s. Khi notch mở có poll thì 0,5-2/s, Cassette tab Media khoảng 5/s. Bộ đếm này tăng rất thưa nên chỉ dùng để so tương đối. Cột `POWER` (Energy Impact) đi theo CPU: 0,00 khi thu gọn, 1,5-2,2 khi mở.

Chưa đo được: thu gọn lúc thật sự không có app nào phát nhạc từ đầu phiên, và tab Media có nhạc sau khi sửa.

## 2. Bộ nhớ

Cách đo: `footprint <pid>` (phys_footprint), `ps -o rss`, `heap`, `leaks`.

| Mốc | Footprint | RSS |
|---|---|---|
| Vừa mở app (3 lần đo, 3 bản build) | 29-30 MB | 57-82 MB |
| Trước 10 lần mở/đóng notch | 42 MB | 75 MB |
| Sau 10 lần | 42 MB | 57 MB |
| Sau 20 lần | 42 MB | 54 MB |
| Gương lần 1: đang mở / sau khi đóng | 142 / 77 MB | 143 MB |
| Gương lần 2: đang mở / sau khi đóng | 139 / 82 MB | 137 MB |
| Gương lần 3: sau khi đóng | 93 MB | 143 MB |
| Cài đặt: mở lần đầu | 30 → 47 MB | 99 MB |
| Cài đặt: sau 4 lần mở/đóng | 47 MB | |
| Sau 3 lần đổi giao diện, bật/tắt thú cưng | 55-59 MB | |

Nhận xét:
- Mở/đóng notch không làm tăng bộ nhớ.
- Cửa sổ Cài đặt được giữ lại để mở nhanh lần sau (theo thiết kế), nên 17 MB không trả lại, nhưng không tăng thêm.
- Gương camera: sau lần đầu, `AVCaptureSession` vẫn giữ input/output đã cấu hình và bộ nhớ của Vision. Footprint không về mức cũ (42 → 77 MB) và còn nhích thêm ở lần 2, 3. `heap` sau khi đóng không còn `AVCaptureVideoPreviewLayer` hay `CameraPreviewView` nào, `leaks` không thấy gì, nên đây là bộ nhớ được giữ lại chứ không phải rò. Malloc Small 58 MB dirty, trong đó 21 MB có thể thu hồi.
- Core Animation: sau 3 lần đổi giao diện (dựng lại toàn bộ view) chỉ còn 1 `NSHostingView<NotchRootView>`. Không thấy layer thú cưng, equalizer hay cửa sổ bay vào khay bị giữ lại.

`leaks`:
- Trước sửa (app chạy khoảng 10 phút, có yêu cầu thật từ Claude Code): 169 leak, 12 688 byte. Toàn bộ là 27 vòng tham chiếu `HookConnection` ↔ closure `onRequest`/`onClose`, 1 `CFString` 80 byte của hệ thống.
- Sau sửa: 0 leak sau 5 yêu cầu hook thật. 0 leak sau các vòng đổi giao diện, thú cưng, Cài đặt.

Đã thử (14/11, đo lại ba lượt): footprint sau khi đóng gương nằm ở khoảng 100 MB và không giảm thêm.
- Tháo input/output của phiên camera 20 s sau khi đóng gương: không đổi gì.
- `malloc_zone_pressure_relief`: không đổi gì.
- Cho Vision chạy trên CPU: CPU tab Gương tăng lên khoảng 20%, phần bộ nhớ Neural Engine vẫn còn.
- `AVCaptureMetadataOutput`: camera FaceTime HD không báo `.face`, nên vẫn phải dùng Vision.
- `CIDetector`: cũng tốn 23 MB như Vision, vì bên trong nó cũng dùng model của Vision.

`heap` cho thấy phần còn lại là model `VNShotflowNetworkANODv4` (Espresso) và bộ đệm của chuỗi xử lý camera. Không có API để nhả các phần này. Đã gỡ hết các thử nghiệm. Cách duy nhất để trả lại bộ nhớ là chạy camera cùng Vision trong một tiến trình phụ rồi tắt tiến trình đó khi đóng gương. Chưa làm.

## 3. Pin và hoạt động nền

| Nguồn | Chu kỳ | Khi nào chạy |
|---|---|---|
| Global/local mouse monitor (`NSEvent`) | theo sự kiện chuột | Luôn có, không poll |
| Timer hover `tick()` | 60 Hz | Chỉ khi notch mở, đang giữ chuột, hoặc đang chờ độ trễ hover |
| `petTimer` (NotchController) | 30 s, tolerance 5 s | Luôn chạy. Thú cưng tắt thì return ngay |
| `PetState.idleTimer` | 20-40 s, một lần rồi hẹn lại | Luôn chạy, kể cả khi tắt thú cưng |
| Animation thú cưng | Core Animation `repeatCount = .infinity` | Khi thú cưng hiện |
| `CalendarStore.timer` | 60 s, tolerance 10 s (mới) | Luôn chạy. Chưa có quyền lịch thì chỉ đọc trạng thái quyền |
| `EKEventStoreChanged` | sự kiện | Luôn có |
| `TrayStore.timer` (dọn khay) | 3600 s | Luôn chạy |
| `ScreenshotWatcher`: timer clipboard | 0,5 s, tolerance 0,2 s | Trước: luôn chạy. Sau sửa: chỉ khi bật "Ảnh chụp vào khay" và tab Khay |
| `ScreenshotWatcher`: `NSMetadataQuery` + KVO `runningApplications` + launch/terminate | sự kiện | Như trên |
| `NowPlaying`: timer AppleScript | 3 s | Trước: mỗi khi MediaRemote không có bài. Sau sửa: chỉ khi adapter MediaRemote chết hoặc không có |
| `NowPlaying`: distributed notification của Spotify, Music | sự kiện | Luôn có |
| Tiến trình `perl` mediaremote stream | sự kiện (chỉ in khi đổi) | Luôn có, 0,00% CPU, khoảng 6 MB |
| Watchdog adapter | một lần sau 6 s | Mỗi lần khởi động stream |
| Thử lại adapter | 2 s, 4 s | Khi stream chết, tối đa 3 lần |
| `AudioSpectrum` process tap + `CADisplayLink` 30 fps | | Chỉ khi bật sóng thật, đang phát, sóng đang hiện, không ở chế độ tiết kiệm pin |
| Thử lại process tap | 1 s, tối đa 8 lần | Khi player chưa mở phiên âm thanh |
| Sóng nhạc giả | Core Animation | Khi đang phát |
| Thanh tiến độ `TimelineView` | 10 fps (trước 30) | Notch mở, tab Media, đang phát |
| Cassette `TimelineView` | 1 s | Giao diện Cassette, tab Media đang mở |
| Cassette gương `TimelineView` | 0,5 s | Tab gương Cassette đang mở |
| `CountdownBadge` `TimelineView` | 1 s | Khi có thẻ Claude đang chờ |
| Viền ô thả file | mỗi khung hình | Trước: luôn chạy khi tab Khay mở. Sau sửa: chỉ khi đang kéo file vào |
| Camera + Vision | tối đa 2 lần/giây | Chỉ khi tab gương đang hiện |
| `SystemMonitor` (Space, app active/terminate, đổi màn hình, Low Power) | sự kiện | Luôn có |
| `BatteryMonitor` (IOKit power source) | sự kiện | Luôn có |
| `AudioDeviceMonitor` (CoreAudio) | sự kiện | Luôn có |
| Socket hook Claude (`DispatchSource` read) | sự kiện | Luôn có |
| Distributed notification `toggle`, `settings`, `onboarding` | sự kiện | Luôn có |
| `com.apple.screenIsLocked` / `screenIsUnlocked` | sự kiện | Luôn có (hiệu ứng mở khoá) |
| FaceUnlockKit `LockMonitor` | sự kiện | Khi đã tạo service (bật tính năng hoặc mở mục Khuôn mặt) |
| FaceUnlockKit `SessionAutoLocker` | 5 phút | Như trên |
| Vòng quét mặt (`Task.sleep` 20 ms) | 20 ms | Chỉ trong lúc quét trên màn hình khoá, tối đa `scanSeconds` (5 s) |
| `SIGTERM` signal source | sự kiện | Luôn có |

Những thứ luôn chạy mà có thể làm theo sự kiện: timer clipboard (không có thông báo đổi clipboard trên macOS, nên giữ poll nhưng đã gate theo cài đặt) và timer AppleScript (đã gate theo adapter). Hai timer thú cưng còn chạy khi tắt thú cưng. Chúng chỉ thức dậy 1 lần mỗi 20-30 s nên tôi để nguyên.

## 4. Camera

Cách kiểm: log `WindowServer` mục `com.apple.SkyLight:StatusIndicator` (đây là đèn camera trên thanh menu) và log `AVCaptureSession` của Roost. Tôi cũng thử `AVCaptureDevice.isInUseByAnotherApplication` từ một tool dòng lệnh, nhưng nó luôn trả `false` kể cả lúc camera bật (tool chạy dưới quyền của Terminal), nên không dùng.

| Lần | `startRunning` | Đèn bật | `stopRunning` | Đèn tắt |
|---|---|---|---|---|
| 1 | 10:06:32.99 | 10:06:34.15 | 10:07:01.67 | 10:07:01.98 |
| 2 | 10:07:20.72 | 10:07:21.97 | khoảng 10:07:24.8 | 10:07:25.07 |
| 3 | | 10:07:42.04 | | 10:07:45.10 |

- Session chỉ chạy khi `MirrorView`/`CassetteMirrorView` hiện (`onAppear`/`onDisappear`). Đóng notch hoặc đổi tab là tắt.
- Vision: trong `sample` lúc gương mở, queue `notch.camera.vision` có hoạt động. Sau khi đóng 1,5 s, CPU về 0,01% và số thread về 8 như trước.
- Mở khoá bằng khuôn mặt (đang tắt trên máy đo) dùng camera riêng của FaceUnlockKit: chỉ khi màn hình khoá thật (kiểm bằng CGSession) hoặc trong cửa sổ quét mặt.
- Không ghi, không lưu khung hình nào. Khung hình cho Vision chỉ là buffer 320×180 trong RAM.

## 5. Quyền ứng dụng có thể xin

| Quyền | Khi nào xin | Ghi chú |
|---|---|---|
| Lịch | Bấm "Cho phép đọc lịch" ở widget lịch, hoặc nút ở màn chào | Lúc mở app chỉ đọc trạng thái |
| Camera | Bấm ở tab gương, màn chào, hoặc mục Khuôn mặt | |
| Automation (Spotify, Music) | Nút ở màn chào. Ngoài ra AppleScript dự phòng tự gửi Apple event khi Spotify/Music đang mở mà MediaRemote không có bài | Sau sửa: không gửi lúc khởi động khi adapter còn sống. Lần hỏi tự động vẫn có thể xảy ra về sau |
| Ghi âm thanh hệ thống | Lần đầu tạo process tap: bật "Sóng nhạc theo âm thanh thật" và có nhạc đang phát | Mặc định tắt |
| Trợ năng | Chỉ khi bấm nút trong Cài đặt > Khuôn mặt | Không gọi ở chỗ nào khác |
| Touch ID / mật khẩu (LocalAuthentication) | Khi lưu mật khẩu, mở phiên dữ liệu khuôn mặt, hoặc quét mặt mở khoá | |
| Keychain | Đọc/ghi mục `local.toan.notch.faceunlock` khi dùng mở khoá bằng khuôn mặt | |
| Input Monitoring, Screen Recording | Không xin | Global monitor chỉ nghe chuột. `CGWindowList` chỉ đọc khung cửa sổ |

Bằng chứng lúc khởi động: log TCC 25 phút gần nhất cho thấy mọi truy vấn liên quan Roost đều là `preflight=yes` (Lịch, Camera, AudioCapture, Microphone, ListenEvent, ScreenCapture…). Đây là framework hệ thống đọc trạng thái, không có hộp thoại. Không có truy vấn `kTCCServiceAccessibility` hay `kTCCServiceAppleEvents` nào sau khi sửa.

## 6. Người dùng thấy gì khi bị từ chối quyền

| Quyền | Khi bị từ chối | Trạng thái |
|---|---|---|
| Lịch | Widget: "Mở Cài đặt để cấp quyền lịch", bấm mở `Privacy_Calendars`. Cassette: "Bấm để cho phép đọc lịch", bị từ chối thì cũng mở Cài đặt | ✅ (chữ ở Cassette hơi lệch khi đã bị từ chối) |
| Camera, tab gương | "Mở Cài đặt để cấp quyền camera", mở `Privacy_Camera` | ✅ |
| Camera, mục Khuôn mặt | Trước: nút "Cấp quyền" không làm gì. Sau sửa: "Mở Cài đặt hệ thống" | ✅ đã sửa |
| Trợ năng | Trước: nút chỉ gọi hộp thoại hệ thống, lần thứ hai không hiện gì. Sau sửa: mở thẳng `Privacy_Accessibility` | ✅ đã sửa |
| Automation | Màn chào có hàng "Mở Cài đặt hệ thống". Notch thì không báo gì, chỉ không có bài Spotify/Music khi MediaRemote cũng không có | ⚠️ còn thiếu |
| Ghi âm thanh hệ thống | Sóng tự quay về hiệu ứng giả. Sau sửa: dưới công tắc có dòng gợi ý và nút mở `Privacy_AudioCapture` | ✅ đã sửa (không phát hiện được từ chối, chỉ gợi ý) |
| Touch ID | Lỗi của LocalAuthentication hiện ở mục Khuôn mặt | ✅ |

Anchor `Privacy_AudioCapture` có trong SecurityPrivacyExtension của macOS 27. Trên macOS 14 có thể không có, khi đó Cài đặt hệ thống mở trang Quyền riêng tư chung.

## 7. Lưu trạng thái

Kiểm bằng cách khởi động lại khoảng 10 lần trong buổi đo (pkill, `kill -9`, build lại) và so `defaults export` với bản sao lưu đầu buổi.

| Trạng thái | Lưu ở | Còn sau khi khởi động lại |
|---|---|---|
| Cài đặt chung (ngôn ngữ, cách mở, phím tắt, màn hình, kích thước, rung, tiết kiệm pin…) | UserDefaults | Có |
| Giao diện (`theme`) | UserDefaults | Có (đổi trong app ghi ngay vào defaults) |
| Thú cưng (`showPet`) | UserDefaults | Có |
| Tab bật/tắt | UserDefaults `tab.*` | Có |
| Khay file | UserDefaults `trayItems` (bookmark) | Có. Đã kiểm: ghi lại, khởi động lại, item còn nguyên |
| Lật gương | UserDefaults `mirrorFlip` | Có |
| Mục Cài đặt đang mở | UserDefaults `settingsPaneID` | Có |
| Cài đặt mở khoá bằng khuôn mặt | UserDefaults `faceUnlock.*` | Có |
| Nhật ký mở khoá (50 dòng) | UserDefaults `faceUnlock.log` | Có |
| Dữ liệu khuôn mặt, mật khẩu | Application Support/Roost/FaceUnlock, Keychain | Có (không đụng tới) |
| "Luôn cho phép" của Claude | UserDefaults `claude.grants` | Có |
| Lịch sử yêu cầu Claude (20 dòng) | Bộ nhớ | Không, mất khi thoát |
| Tab đang chọn trên notch | Bộ nhớ | Không, luôn mở tab Media |
| Phiên Touch ID của mở khoá bằng khuôn mặt | Bộ nhớ | Không, theo thiết kế (mở lại mỗi lần chạy app) |
| Tuần đang xem ở lịch, lựa chọn và bộ lọc khay | Bộ nhớ | Không, theo thiết kế |

Lưu ý về khay: trong buổi đo, `trayItems` có lúc thành rỗng dù file gốc (một PDF trong Downloads) vẫn còn. Tôi không tái hiện được lỗi này qua mở tab Khay, đổi giao diện hay khởi động lại, nên không rõ do người dùng tự gỡ hay do app. Đã khôi phục từ bản sao lưu và kiểm là item sống qua lần khởi động lại. Điểm đáng sửa: `TrayStore.prune()` bỏ item khi resolve bookmark hoặc `fileExists` thất bại vì bất kỳ lý do gì (chưa có quyền thư mục, ổ ngoài chưa gắn), không chỉ khi file đã bị xoá.

## 8. Hook Claude khi app chết

Chạy lại `python3 -I test_hook.py --real` (script có sẵn, không sửa). Script dùng socket giả cho ca 1-10. Ca 11-14 gửi yêu cầu thật tới Roost, `pkill` Roost rồi mở lại.

Kết quả: 16/16 PASS.

| Ca | Kết quả |
|---|---|
| Trả lời hợp lệ / hỏng / EOF / im lặng | 0,51 s / 0,52 s / 1,02 s / 3,02 s |
| Socket cũ, không có socket | 0,012 s, 0,008 s |
| App không đọc payload 5 MB, PostToolUse kẹt | 3,01 s, 2,01 s |
| Claude Code bị kill, stdin không đóng | hook thoát sau 0,01 s, watchdog 4,03 s |
| App thật, không ai bấm | 4,01 s |
| PostToolUse phiên A chỉ gỡ thẻ A | A 1,52 s, B 8,04 s |
| App bị kill giữa lúc chờ | hook thoát 0,02 s sau pkill |
| App chết, file socket còn sót | 0,015 s |
| Mở lại Roost | đang nghe |

Thêm ca crash thật (`kill -9`): file socket cũ còn lại (inode 362071334). Tiến trình perl mồ côi còn sống tới lần mở app sau và bị `killOrphans` dọn. Mở lại app: socket được `unlink` rồi tạo mới (inode 362071468). Gửi một yêu cầu thật thì hook chờ đúng 3,01 s (app đã nhận, không ai bấm), không treo.

## 9. Phân phối

Hiện trạng (`codesign -dv --verbose=4`, `codesign -d --entitlements -`, `spctl -a -vvv`, `stapler validate`):
- Authority: "Notch Local Signing" (chứng chỉ tự tạo bằng `scripts/make-signing-cert.sh`). `security find-identity -v -p codesigning`: 0 identity hợp lệ. Hai chứng chỉ Apple Development cũ trong keychain đã hết hạn hoặc bị thu hồi.
- TeamIdentifier: not set. CodeDirectory flags 0x0: không hardened runtime. Không có entitlement.
- Gatekeeper: `rejected`. Chưa notarize, không có ticket.
- Mọi binary (`Roost`, `roost-hook`, `MediaRemoteAdapter.framework`) chỉ có arm64.
- Không có cơ chế cập nhật.

Cần để phát hành ngoài máy này:
1. Tài khoản Apple Developer và chứng chỉ "Developer ID Application".
2. Ký từng phần từ trong ra ngoài với `--options runtime --timestamp`: framework, `roost-hook`, rồi app. Bỏ `cp` file sau khi ký.
3. Entitlement cho hardened runtime:
   - `com.apple.security.device.camera` (gương, mở khoá bằng khuôn mặt)
   - `com.apple.security.automation.apple-events` (AppleScript tới Spotify/Music)
   - `com.apple.security.personal-information.calendars` (EventKit)
   - Process tap âm thanh hệ thống: cần chạy thử dưới hardened runtime. Có thể phải thêm `com.apple.security.device.audio-input`.
   - Keychain: app không sandbox dùng login keychain nên không cần `keychain-access-groups`. Đổi chứng chỉ thì ACL của mục keychain cũ sẽ hỏi lại một lần.
4. `xcrun notarytool submit --wait` rồi `xcrun stapler staple`. Đóng gói dmg hoặc zip.
5. Cơ chế cập nhật: chưa có. Gợi ý Sparkle 2 (khoá EdDSA, appcast trên GitHub Releases).
6. Đổi chứng chỉ ký sẽ đổi designated requirement. Người dùng phải cấp lại Lịch, Camera, Automation, Trợ năng, âm thanh hệ thống một lần.

Ký bản phát hành (từ 2026-11-17, trước khi có Developer ID):
- `scripts/make-dmg.sh` ký bằng chứng chỉ tự ký "Roost Release Signing" và dừng nếu máy không có chứng chỉ này. Không bao giờ phát hành bản ký ad-hoc: designated requirement của bản ad-hoc là `cdhash`, nên mỗi bản cập nhật làm mọi người dùng mất hết quyền (Trợ năng, Camera, Lịch, Automation, âm thanh). Bản 1.0.0 đến 1.0.3 bị lỗi này.
- Designated requirement đúng: `identifier "io.github.letoan1.roost" and certificate leaf = H"918a0464db5b814d0ae99d25c57e906747e6b13e"`. Kiểm tra bằng `codesign -d -r- Roost.app`.
- Khoá riêng của chứng chỉ phải được sao lưu (.p12) cùng chỗ với khoá EdDSA của Sparkle. Mất khoá thì mọi người dùng phải cấp lại quyền thêm một lần.
- Bản đầu tiên ký bằng chứng chỉ này vẫn khiến người dùng cũ phải cấp lại quyền một lần. Ghi rõ trong release notes.

Rủi ro cần quyết định trước khi phát hành:
- Model ArcFace (InsightFace) đi kèm có giấy phép chỉ cho dùng phi thương mại (xem `Packages/FaceUnlockKit/NOTICE.md`).
- `mediaremote-adapter` dựa vào việc `/usr/bin/perl` được dùng MediaRemote. Apple có thể chặn đường này ở bản macOS sau. App đã có AppleScript dự phòng cho Spotify/Music.
- Mở khoá bằng khuôn mặt gõ mật khẩu đăng nhập bằng CGEvent. Cần mô tả rõ rủi ro bảo mật cho người dùng.

## 10. Tương thích

- Mục tiêu tối thiểu: `Package.swift` `.macOS(.v14)`, FaceUnlockKit `.macOS(.v14)`, Info.plist `LSMinimumSystemVersion` 14.0, `LC_BUILD_VERSION` minos 14.0. Framework MediaRemoteAdapter build với `-mmacosx-version-min=14.0`. Ghi chú: `LC_BUILD_VERSION` ghi `sdk 14.0` dù toolchain là SDK 27.2.
- API mới hơn 14.0: `CATapDescription`, `AudioHardwareCreateProcessTap` (14.2) được bọc `#available(macOS 14.2, *)` / `@available`. Các API còn lại (EventKit full access, `NSView.displayLink`, `onChange` hai tham số, `AVCaptureDevice.DeviceType.external`) đều có từ 14.0. Trình biên dịch với deployment target 14.0 không báo lỗi availability nào, chỉ có cảnh báo deprecated (`sharingServices(forItems:)`).
- Không dùng FoundationModels hay API của macOS 26 trở lên.
- Kiến trúc: chỉ arm64. Muốn chạy trên Intel cần `swift build --arch arm64 --arch x86_64` và `clang -arch arm64 -arch x86_64` cho framework.
- Máy không có notch: có chế độ notch vẽ và viên nổi (`noNotchStyle`), có `displayMode` cho nhiều màn hình.

Chưa kiểm:
- macOS 14.x, 15.x, 26.x (chỉ chạy trên 27.2.1).
- Máy Intel (không build được bản x86_64).
- Máy không có notch, màn hình ngoài là màn chính, Stage Manager.
- Anchor `Privacy_AudioCapture` trên macOS 14.
- Hành vi MediaRemote qua perl trên macOS 14 (ở đó MediaRemote còn mở cho app thường).

## Cần quyết định

1. Viền nét đứt của ô thả file giờ chỉ chạy khi kéo file vào. Nếu muốn giữ hiệu ứng chạy liên tục, cần làm lại bằng `CAShapeLayer` (chạy ở render server) thay vì SwiftUI `repeatForever`.
2. Thanh tiến độ nhạc giảm từ 30 xuống 10 khung/giây. Với bài ngắn (dưới 1 phút) có thể thấy thanh bước nhẹ.
3. AppleScript dự phòng vẫn có thể tự bật hộp thoại Automation khi Spotify/Music mở mà MediaRemote không có bài. Có thể chỉ chạy dự phòng sau khi người dùng đã cấp ở màn chào.
4. Vòng poll chuột 60 Hz khi notch mở tốn khoảng 1,5-1,7% CPU. Hạ xuống 30 Hz sẽ còn khoảng một nửa, nhưng cần thử lại cảm giác đóng/mở.
5. Phiên camera giữ 35-50 MB sau khi đóng gương.

## Công cụ đo

Script và kết quả thô nằm trong scratchpad của phiên audit (sẽ bị dọn): `measure.sh`, `camcheck`, `rwins`, các file `sample-*.txt`, `leaks1.txt`, `leaks2.txt`, `tcc.log`.

## Quyết định sau audit (14/11/2026)

- Giữ hai thay đổi về hình: viền ô thả file chỉ chạy khi đang kéo file, thanh tiến độ nhạc 10 khung hình/giây.
- Đã giảm nhịp kiểm chuột khi notch mở từ 60 xuống 30 lần/giây. Notch đóng chậm thêm tối đa 17 ms, không cảm nhận được.
- Không giải phóng hẳn phiên camera sau khi đóng tab Gương. Làm vậy trả lại 35–50 MB nhưng mở lại tab Gương sẽ chậm thêm khoảng nửa tới một giây.
- Khay không còn tự gỡ file khi lỗi chỉ thoáng qua: chỉ gỡ khi file vào Thùng rác, hoặc vẫn không thấy file sau ít nhất 10 phút.
