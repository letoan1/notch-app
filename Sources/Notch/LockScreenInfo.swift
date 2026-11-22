import AppKit
import Combine
import SwiftUI

// MARK: - Widget dưới đồng hồ màn hình khoá

/// Một dòng thông tin ngay dưới đồng hồ của macOS: ngày âm lịch, cuộc họp kế tiếp, pin, câu tự viết.
/// Đồng hồ là của macOS (không đổi được); dòng này là cửa sổ riêng của Roost, chỉ tồn tại khi máy khoá.
/// Hiện / cất theo LockScreenMusic (cùng tín hiệu khoá, mở khoá, màn hình ngủ).
@MainActor
final class LockScreenInfo: ObservableObject {
    static let shared = LockScreenInfo()

    @Published var enabled: Bool { didSet { save(enabled, "enabled") } }
    @Published var lunar: Bool { didSet { save(lunar, "lunar") } }
    @Published var meeting: Bool { didSet { save(meeting, "meeting") } }
    @Published var battery: Bool { didSet { save(battery, "battery") } }
    @Published var note: String { didSet { save(note, "note") } }

    /// Có gì để hiện không (bật mà chọn trống hết thì không dựng cửa sổ).
    var hasContent: Bool {
        enabled && (lunar || meeting || battery || !note.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// LockScreenMusic gọi lại khi cài đặt đổi (để hiện / cất ngay lúc đang khoá).
    var onChange: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "lockInfo.enabled")
        lunar = d.object(forKey: "lockInfo.lunar") as? Bool ?? Lang.isVietnamese
        meeting = d.object(forKey: "lockInfo.meeting") as? Bool ?? true
        battery = d.object(forKey: "lockInfo.battery") as? Bool ?? false
        note = d.string(forKey: "lockInfo.note") ?? ""
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: "lockInfo." + key)
        onChange?()
    }

    /// Dòng âm lịch: "Mùng 3 tháng 10, năm Bính Ngọ" / "Lunar 10/3, Year of Bính Ngọ".
    static func lunarText(_ date: Date) -> String {
        let l = LunarDate(solar: date)
        let month = "\(l.month)" + (l.leap ? L(" nhuận", " (leap)") : "")
        let day = l.day <= 10 ? "Mùng \(l.day)" : "\(l.day)"
        return L("\(day) tháng \(month), năm \(l.canChiYear)", "Lunar \(month)/\(l.day), year \(l.canChiYear)")
    }
}

/// Cửa sổ không lấy focus, nằm ngay dưới đồng hồ (đồng hồ macOS kết thúc khoảng 26% từ trên xuống).
final class LockInfoWindow: NSPanel {
    static let height: CGFloat = 40

    @MainActor
    init(calendar: CalendarStore) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSHostingView(rootView: LockInfoView(calendar: calendar))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    @MainActor
    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let f = screen.frame
        let width = min(f.width * 0.7, 900)
        let top = f.maxY - f.height * 0.265
        setFrame(NSRect(x: f.midX - width / 2, y: top - Self.height, width: width, height: Self.height), display: true)
    }
}

struct LockInfoView: View {
    @ObservedObject var calendar: CalendarStore   // vẽ lại ở các mốc giờ (nửa đêm, họp bắt đầu / kết thúc)
    @ObservedObject var info = LockScreenInfo.shared
    @ObservedObject var system = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 18) {
            let now = Date()
            if info.lunar {
                item("moon.stars", LockScreenInfo.lunarText(now))
            }
            if info.meeting, let e = calendar.nextEvent {
                let f = Self.time
                item("calendar", e.start <= now
                     ? L("Đang họp: \(e.title)", "Now: \(e.title)")
                     : "\(f.string(from: e.start)) \(e.title)")
            }
            if info.battery, let p = system.batteryPercent {
                item(system.batteryCharging ? "battery.100.bolt" : Self.batterySymbol(p), "\(p)%")
            }
            let note = info.note.trimmingCharacters(in: .whitespaces)
            if !note.isEmpty {
                Text(note).font(font(16)).italic()
            }
        }
        .lineLimit(1)
        .foregroundStyle(Theme.isVanGogh ? VG.yellow : .white)
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            if !Theme.isPixel { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).opacity(0.85) }
            Text(text).font(font(16))
        }
    }

    /// Mặc định / Cassette: SF; Pixel: VT323; Van Gogh: chữ có chân như thư viết tay.
    private func font(_ size: CGFloat) -> Font {
        if Theme.isPixel { return .custom("VT323", size: size * 1.35) }
        if Theme.isVanGogh { return .system(size: size + 1, weight: .medium, design: .serif) }
        if Theme.isCassette { return .system(size: size, weight: .semibold, design: .monospaced) }
        return .system(size: size, weight: .semibold, design: .rounded)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func batterySymbol(_ p: Int) -> String {
        p > 87 ? "battery.100" : p > 62 ? "battery.75" : p > 37 ? "battery.50" : p > 12 ? "battery.25" : "battery.0"
    }
}
