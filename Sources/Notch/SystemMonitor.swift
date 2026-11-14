import AppKit
import Combine

/// Trạng thái máy ảnh hưởng tới notch, theo sự kiện (không poll):
/// - màn hình nào đang có app toàn màn hình (video, game, trình chiếu) → notch tối giản;
/// - Low Power Mode hoặc pin ≤ 20% khi không cắm sạc → tắt hiệu ứng tốn pin.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var fullscreenDisplays: Set<CGDirectDisplayID> = []
    @Published private(set) var lowPower = false

    private let settings = SettingsStore.shared
    private var battery: BatteryMonitor.Status?
    private var cancellables = Set<AnyCancellable>()

    func start(battery monitor: BatteryMonitor) {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullscreenCheck() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFullscreenCheck() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePower() }
        }
        monitor.onUpdate = { [weak self] status in
            MainActor.assumeIsolated {
                self?.battery = status
                self?.updatePower()
            }
        }
        battery = BatteryMonitor.read()
        settings.$powerSaver.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePower() }
        }.store(in: &cancellables)
        settings.$autoMinimal.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullscreen() }
        }.store(in: &cancellables)
        updatePower()
        checkFullscreen()
    }

    private func updatePower() {
        let lowBattery = battery.map { !$0.onAC && $0.percent <= 20 } ?? false
        let value = settings.powerSaver && (ProcessInfo.processInfo.isLowPowerModeEnabled || lowBattery)
        if value != lowPower { lowPower = value }
    }

    /// Hiệu ứng chuyển Space mất ~0.5s: kiểm tra ngay và kiểm tra lại sau khi chuyển xong.
    private func scheduleFullscreenCheck() {
        checkFullscreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.checkFullscreen() }
        }
    }

    /// Màn hình có cửa sổ (app khác, lớp thường) phủ kín đúng khung màn hình = đang toàn màn hình.
    /// Đọc khung cửa sổ không cần quyền Screen Recording.
    private func checkFullscreen() {
        var result: Set<CGDirectDisplayID> = []
        if settings.autoMinimal,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let me = ProcessInfo.processInfo.processIdentifier
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                let f = screen.frame
                let cg = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
                let covered = list.contains { w in
                    guard (w[kCGWindowLayer as String] as? Int) == 0,
                          (w[kCGWindowOwnerPID as String] as? Int32) != me,
                          (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                          let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
                    else { return false }
                    return abs(x - cg.minX) < 1 && abs(y - cg.minY) < 1 && abs(width - cg.width) < 1 && abs(height - cg.height) < 1
                }
                if covered { result.insert(id) }
            }
        }
        if result != fullscreenDisplays { fullscreenDisplays = result }
    }
}
