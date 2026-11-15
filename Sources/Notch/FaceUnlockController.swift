import AppKit
import Combine
import FaceUnlockKit
import SwiftUI

/// Một dòng nhật ký mở khoá bằng khuôn mặt (lưu cục bộ, tối đa 50 dòng).
struct UnlockLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let success: Bool
    let reason: String
}

/// Điều phối mở khoá bằng khuôn mặt cho cả app:
/// - Lớp 1 (luôn có nếu bật "Hiệu ứng Face ID"): biểu tượng Face ID cạnh notch trên màn hình khoá,
///   mở khoá xong (bằng bất kỳ cách nào) thì notch chạy hiệu ứng quét → ✓ + "Chào <tên>".
/// - Lớp 2 (tính năng thử nghiệm, mặc định tắt): FaceUnlockService quét mặt và gõ mật khẩu.
/// Không có đường IPC / distributed notification nào của Roost gọi được tới quét hay gõ phím:
/// quét chỉ chạy từ trigger của FaceUnlockKit (khoá / thức, kiểm tra CGSession) hoặc từ rê chuột
/// thật lên cửa sổ trên màn hình khoá.
@MainActor
final class FaceUnlockController: ObservableObject {
    static let shared = FaceUnlockController()
    static let defaultsPrefix = "faceUnlock"
    static let maxFailures = 5
    static let defaultIdleLimit: TimeInterval = 8 * 3600

    /// Chỉ tạo khi cần (bật tính năng hoặc mở Cài đặt) rồi giữ suốt đời app: tải model tốn ~0.1–0.5s.
    @Published private(set) var service: FaceUnlockService?
    @Published private(set) var log: [UnlockLogEntry] = []
    /// Số lần quét thất bại liên tiếp trong lần khoá máy hiện tại.
    @Published private(set) var failures = 0
    /// Đủ `maxFailures` lần → ngừng quét (tự động lẫn rê chuột) tới khi người dùng tự mở khoá.
    @Published private(set) var suspended = false
    /// Đang hiện trên màn hình khoá (đã xác nhận bằng CGSession).
    @Published private(set) var lockActive = false

    /// Mở khoá xong (mọi cách): NotchController hiện lời chào trên notch.
    var onUnlock: ((String) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var overlay: LockOverlayWindow?
    private let logKey = "faceUnlock.log"

    private init() {
        if let data = UserDefaults.standard.data(forKey: logKey),
           let entries = try? JSONDecoder().decode([UnlockLogEntry].self, from: data) {
            log = entries
        }
    }

    /// Bật trong Cài đặt (đọc thẳng UserDefaults khi service chưa tạo).
    var isEnabled: Bool {
        service?.settings.isEnabled ?? (UserDefaults.standard.object(forKey: "\(Self.defaultsPrefix).isEnabled") as? Bool ?? false)
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        // Thông báo khoá / mở khoá của macOS giả mạo được → chỉ dùng làm tín hiệu, luôn xác nhận lại bằng CGSession.
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated { self?.checkLocked() }
            }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self?.checkUnlocked() }
            }
        })
        if isEnabled { ensureService() }
    }

    /// Tạo service (một lần). Lần đầu ghi các mặc định an toàn: liveness nặng, phiên 8 giờ.
    @discardableResult
    func ensureService() -> FaceUnlockService {
        if let service { return service }
        let d = UserDefaults.standard
        let p = Self.defaultsPrefix
        if d.object(forKey: "\(p).livenessMode") == nil { d.set(FaceUnlockLivenessMode.heavy.rawValue, forKey: "\(p).livenessMode") }
        if d.object(forKey: "\(p).sessionIdleLimit") == nil { d.set(Self.defaultIdleLimit, forKey: "\(p).sessionIdleLimit") }
        let s = FaceUnlockService(configuration: FaceUnlockConfiguration(
            // Giữ nguyên tên cũ (từ thời app tên Notch) để vẫn tìm thấy mật khẩu / khoá phiên đã lưu.
            keychainService: "local.toan.notch.faceunlock",
            storageDirectoryName: "Roost/FaceUnlock",
            defaultsPrefix: p,
            // Model được build.sh chép vào Contents/Resources/ArcFaceModel (tìm theo tên, không qua Bundle.module).
            modelURL: Bundle.main.url(forResource: "ArcFaceModel", withExtension: nil),
            credentialProtection: .localAuthenticationGate,   // chứng chỉ tự ký: không dùng được keychain userPresence
            modelCachePolicy: .perLaunch
        ))
        s.autoScanSuspended = suspended
        s.$phase.dropFirst().sink { [weak self] phase in
            self?.phaseChanged(phase)
        }.store(in: &cancellables)
        // Chuyển tiếp thay đổi để view theo dõi controller cũng vẽ lại.
        s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        service = s
        return s
    }

    // MARK: - Khoá / mở khoá

    private func checkLocked() {
        guard FaceUnlockService.isScreenActuallyLocked, !lockActive else { return }
        lockActive = true
        failures = 0
        setSuspended(false)
        if SettingsStore.shared.unlockEffect || isEnabled { showOverlay() }
    }

    private func checkUnlocked() {
        guard !FaceUnlockService.isScreenActuallyLocked, lockActive else { return }
        lockActive = false
        hideOverlay()
        failures = 0
        setSuspended(false)
        if SettingsStore.shared.unlockEffect { onUnlock?(Self.greetingName) }
    }

    /// Tên gọi: tên người Việt ở cuối ("Lê Văn Toản" → "Toản"), tên Tây ở đầu.
    static var greetingName: String {
        let parts = NSFullUserName().split(separator: " ").map(String.init)
        guard let first = parts.first, let last = parts.last else { return NSUserName() }
        let vietnamese = Lang.isVietnamese || NSFullUserName().unicodeScalars.contains { $0.value > 0x7F }
        return vietnamese ? last : first
    }

    private func showOverlay() {
        let window = overlay ?? LockOverlayWindow(controller: self)
        overlay = window
        window.place()
        window.orderFrontRegardless()
        // Chỉ chuyển lên được khi máy thật sự đang khoá; không được thì cất đi (không để lại trên desktop).
        if !FaceUnlockService.moveToLockScreen(window) { window.orderOut(nil) }
    }

    private func hideOverlay() {
        guard let overlay else { return }
        FaceUnlockService.restoreFromLockScreen(overlay)
        overlay.orderOut(nil)
    }

    // MARK: - Quét

    /// Rê chuột thật lên notch trên màn hình khoá.
    func hoverScan() {
        guard let service, service.settings.isEnabled, !suspended, lockActive,
              FaceUnlockService.isScreenActuallyLocked else { return }
        switch service.phase {
        case .scanning, .matched: return
        default: service.startScan()
        }
    }

    /// " · 1.9s (camera 0.6s · khớp 0.4s · người thật 1.2s)": biết chậm ở bước nào.
    private static func timingNote(_ t: (camera: Double, face: Double?, match: Double?, live: Double?, total: Double)?) -> String {
        guard let t else { return "" }
        func f(_ v: Double) -> String { String(format: "%.1fs", v) }
        var parts = ["camera " + f(t.camera)]
        if let m = t.match { parts.append(L("khớp ", "match ") + f(m)) }
        if let l = t.live { parts.append(L("người thật ", "liveness ") + f(l)) }
        return " · " + f(t.total) + " (" + parts.joined(separator: " · ") + ")"
    }

    private func phaseChanged(_ phase: FaceUnlockPhase) {
        switch phase {
        case .unlocked:
            append(success: true, reason: L("Nhận ra khuôn mặt", "Face recognized") + Self.timingNote(service?.lastScanTiming))
        case .failed(let failure):
            var reason = Self.describe(failure)
            if case .notRecognized = failure, let s = service?.lastBestSimilarity {
                reason += L(" · giống nhất \(String(format: "%.2f", s)) / ngưỡng \(String(format: "%.2f", service?.settings.matchThreshold ?? 0))",
                            " · best \(String(format: "%.2f", s)) / threshold \(String(format: "%.2f", service?.settings.matchThreshold ?? 0))")
            }
            append(success: false, reason: reason)
            guard Self.counts(failure), lockActive else { return }
            failures += 1
            if failures >= Self.maxFailures, !suspended {
                setSuspended(true)
                service?.cancelScan()
                append(success: false, reason: L("Sai \(Self.maxFailures) lần liên tiếp nên tạm dừng quét, cho tới khi bạn mở khoá bằng cách khác",
                                                 "\(Self.maxFailures) failed tries in a row, so scanning is paused until you unlock another way"))
            }
        default:
            break
        }
    }

    private func setSuspended(_ value: Bool) {
        suspended = value
        service?.autoScanSuspended = value
    }

    /// Lần thử thật sự (có mặt / có gõ) mới tính vào giới hạn; thiếu điều kiện hay không thấy mặt thì không.
    private static func counts(_ failure: FaceUnlockFailure) -> Bool {
        switch failure {
        case .notRecognized, .livenessFailed, .unlockNotConfirmed, .injectionFailed: return true
        case .noFace, .cameraUnavailable, .notReady: return false
        }
    }

    static func describe(_ failure: FaceUnlockFailure) -> String {
        switch failure {
        case .notRecognized: return L("Không nhận ra khuôn mặt", "Face not recognized")
        case .livenessFailed(let why): return L("Không xác nhận được mặt thật", "Couldn't confirm a live face") + " (\(why))"
        case .noFace: return L("Không thấy khuôn mặt", "No face detected")
        case .cameraUnavailable(let why): return L("Camera không dùng được", "Camera unavailable") + " (\(why))"
        case .notReady(let why): return L("Chưa sẵn sàng", "Not ready") + " (\(why))"
        case .injectionFailed(let why): return L("Không gõ được mật khẩu", "Couldn't type the password") + " (\(why))"
        case .unlockNotConfirmed: return L("Đã gõ mật khẩu nhưng máy vẫn khoá (mật khẩu đã đổi?)",
                                           "Password typed but the Mac stayed locked (password changed?)")
        }
    }

    /// Lý do ngắn cho notch trên màn hình khoá.
    static func shortReason(_ failure: FaceUnlockFailure) -> String {
        switch failure {
        case .notRecognized: return L("Không nhận ra", "Not recognized")
        case .livenessFailed: return L("Không phải mặt thật?", "Not a live face?")
        case .noFace: return L("Không thấy mặt", "No face")
        case .cameraUnavailable: return L("Lỗi camera", "Camera error")
        case .notReady: return L("Chưa thiết lập", "Not set up")
        case .injectionFailed: return L("Lỗi gõ mật khẩu", "Typing failed")
        case .unlockNotConfirmed: return L("Sai mật khẩu?", "Wrong password?")
        }
    }

    // MARK: - Nhật ký

    private func append(success: Bool, reason: String) {
        // Gộp lỗi giống hệt lặp lại trong 30s (rê chuột nhiều lần khi chưa thiết lập).
        if let last = log.first, !success, !last.success, last.reason == reason,
           Date().timeIntervalSince(last.date) < 30 { return }
        log.insert(UnlockLogEntry(date: Date(), success: success, reason: reason), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
        saveLog()
    }

    func clearLog() {
        log.removeAll()
        saveLog()
    }

    private func saveLog() {
        if let data = try? JSONEncoder().encode(log) { UserDefaults.standard.set(data, forKey: logKey) }
    }
}

// MARK: - Cửa sổ trên màn hình khoá

/// Bản sao nhỏ của notch (đen, cùng kích thước) + 2 cánh, đưa lên màn hình khoá bằng SkyLight.
/// Nhận rê chuột (quét khi bật tính năng); ẩn ngay khi mở khoá.
final class LockOverlayWindow: NSPanel {
    private let geometry = NotchModel()
    static let size = CGSize(width: 520, height: 90)

    @MainActor
    init(controller: FaceUnlockController) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSHostingView(rootView: LockOverlayView(controller: controller, geometry: geometry))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    @MainActor
    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        geometry.update(for: screen)
        let f = screen.frame
        setFrame(NSRect(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height,
                        width: Self.size.width, height: Self.size.height), display: true)
    }
}
