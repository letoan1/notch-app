import AppKit
import AVFoundation
import EventKit
import FaceUnlockKit

// Báo khi một tính năng đang bật mà thiếu quyền macOS, thường gặp nhất là ngay sau khi cập nhật:
// đổi chữ ký app thì macOS coi là app khác và quyền cũ mất tác dụng, dù System Settings có khi vẫn hiện
// Roost đang bật. Không báo thì tính năng chỉ im lặng không chạy.
//
// Chỉ báo quyền từng thấy được cấp (đã mất), hoặc quyền của tính năng người dùng tự bật (mở khoá bằng
// khuôn mặt). Lần chạy đầu của phiên bản có PermissionWatch thì chưa biết quyền nào từng được cấp, nên
// cho báo một lần. Mỗi quyền báo tối đa một lần mỗi bản build.

@MainActor
final class PermissionWatch: ObservableObject {
    static let shared = PermissionWatch()

    enum Perm: String, CaseIterable {
        case accessibility, camera, calendar

        var name: String {
            switch self {
            case .accessibility: return L("Trợ năng", "Accessibility")
            case .camera: return L("Camera", "Camera")
            case .calendar: return L("Lịch", "Calendars")
            }
        }

        var pane: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .camera: return "Privacy_Camera"
            case .calendar: return "Privacy_Calendars"
            }
        }
    }

    enum Status { case granted, notDetermined, denied }

    /// Để giao diện Cài đặt vẽ lại khi quyền Trợ năng đổi (AXIsProcessTrusted không tự báo cho SwiftUI).
    @Published private(set) var accessibilityTrusted = FaceUnlockService.isAccessibilityTrusted

    /// Các quyền đang thiếu đã báo trên thẻ.
    private(set) var missing: [Perm] = []

    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard
    private static let bootstrapKey = "perm.watch.v1"
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    func start() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { PermissionWatch.shared.check() } }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PermissionWatch.shared.check() }
        })
        // Đợi notch dựng xong và các thẻ lúc mở app (pin, mạng) qua đi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { PermissionWatch.shared.check() } }
    }

    func status(_ perm: Perm) -> Status {
        switch perm {
        case .accessibility:
            return FaceUnlockService.isAccessibilityTrusted ? .granted : .denied
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        }
    }

    /// Có tính năng đang bật cần quyền này không.
    private func needed(_ perm: Perm) -> Bool {
        let faceUnlock = FaceUnlockController.shared.isEnabled
        switch perm {
        case .accessibility: return AlertSettings.shared.hud || faceUnlock
        case .camera: return faceUnlock
        case .calendar: return SettingsStore.shared.showCalendar
        }
    }

    /// Người dùng tự bật tính năng này (không phải mặc định), nên thiếu quyền là đáng báo dù chưa từng thấy cấp.
    private func optedIn(_ perm: Perm) -> Bool {
        switch perm {
        case .accessibility, .camera: return FaceUnlockController.shared.isEnabled
        case .calendar: return false
        }
    }

    func check() {
        accessibilityTrusted = FaceUnlockService.isAccessibilityTrusted
        let bootstrap = !defaults.bool(forKey: Self.bootstrapKey)
        defaults.set(true, forKey: Self.bootstrapKey)

        var lost: [Perm] = []
        for perm in Perm.allCases {
            if status(perm) == .granted {
                defaults.set(true, forKey: "perm.seen.\(perm.rawValue)")
                continue
            }
            guard needed(perm) else { continue }
            let seen = defaults.bool(forKey: "perm.seen.\(perm.rawValue)")
            guard seen || optedIn(perm) || bootstrap else { continue }
            lost.append(perm)
        }

        // Quyền đã được cấp lại: gỡ thẻ đang hiện.
        missing = missing.filter { lost.contains($0) }
        if missing.isEmpty { AlertCenter.shared.dismiss(.permissionLost) }

        let fresh = lost.filter { defaults.string(forKey: "perm.alerted.\($0.rawValue)") != build }
        guard !fresh.isEmpty else { return }
        for perm in fresh { defaults.set(build, forKey: "perm.alerted.\(perm.rawValue)") }
        missing = lost
        postCard()
    }

    private func postCard() {
        guard let first = missing.first else { return }
        let names = ListFormatter.localizedString(byJoining: missing.map(\.name))
        let what: String
        switch first {
        case .accessibility:
            what = AlertSettings.shared.hud
                ? L("HUD âm lượng và độ sáng", "The volume and brightness HUD")
                : L("Mở khoá bằng khuôn mặt", "Face unlock")
        case .camera: what = L("Mở khoá bằng khuôn mặt", "Face unlock")
        case .calendar: what = L("Tab Lịch", "The Calendar tab")
        }
        AlertCenter.shared.post(NotchAlert(
            kind: .permissionLost,
            title: L("Roost chưa có quyền \(names)", "Roost doesn't have \(names) access"),
            highlight: nil,
            subtitle: L("\(what) sẽ không chạy. Vừa cập nhật thì macOS có thể đã gỡ quyền cũ. Bấm để cấp lại.",
                        "\(what) won't work. After an update macOS may drop the old permission. Click to grant it again."),
            icon: .symbol("lock.shield"), tone: .yellow, priority: 1, duration: 12, action: .grantPermission))
    }

    /// Bấm vào thẻ: xin quyền đầu tiên còn thiếu. macOS chỉ hiện hộp thoại khi chưa từng hỏi,
    /// còn lại mở thẳng mục tương ứng trong System Settings.
    func grantFirstMissing() {
        guard let perm = missing.first(where: { status($0) != .granted }) else { return }
        switch (perm, status(perm)) {
        case (.accessibility, _):
            FaceUnlockService.promptForAccessibility()
            openPane(perm)
        case (.camera, .notDetermined):
            Task { _ = await FaceUnlockService.requestCameraAccess(); check() }
        case (.calendar, .notDetermined):
            EKEventStore().requestFullAccessToEvents { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { PermissionWatch.shared.check() } }
            }
        default:
            openPane(perm)
        }
    }

    private func openPane(_ perm: Perm) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(perm.pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
