import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Cài đặt người dùng, lưu UserDefaults. Một instance dùng chung cho cả app.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum Language: String, CaseIterable, Identifiable {
        case auto, vi, en
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("Tự động (theo hệ thống)", "Automatic (system)")
            case .vi: return "Tiếng Việt"
            case .en: return "English"
            }
        }
    }

    enum OpenMode: String, CaseIterable, Identifiable {
        case hover, click
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hover: return L("Rê chuột vào", "Hover")
            case .click: return L("Bấm vào notch", "Click the notch")
            }
        }
    }

    enum DisplayMode: String, CaseIterable, Identifiable {
        case notch, all, mouse, main
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notch: return L("Màn hình có notch", "Screen with a notch")
            case .all: return L("Tất cả màn hình (đồng bộ)", "All screens (synced)")
            case .mouse: return L("Màn hình đang có con trỏ", "Screen with the pointer")
            case .main: return L("Màn hình chính", "Main screen")
            }
        }
    }

    /// Màn hình không có notch thật: vẽ notch dính mép trên, hoặc viên nổi kiểu Dynamic Island.
    enum NoNotchStyle: String, CaseIterable, Identifiable {
        case notch, pill
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notch: return L("Notch vẽ", "Drawn notch")
            case .pill: return L("Viên nổi (Dynamic Island)", "Floating pill (Dynamic Island)")
            }
        }
    }

    /// Phím tắt có sẵn. Tránh ⌃Space / ⌃⌥Space: macOS dùng để đổi bộ gõ.
    enum Hotkey: String, CaseIterable, Identifiable {
        case off, optionSpace, ctrlOptionN, ctrlOptionM
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return L("Tắt", "Off")
            case .optionSpace: return "⌥ Space"
            case .ctrlOptionN: return "⌃ ⌥ N"
            case .ctrlOptionM: return "⌃ ⌥ M"
            }
        }
        /// (keyCode, modifiers Carbon)
        var carbon: (UInt32, UInt32)? {
            switch self {
            case .off: return nil
            case .optionSpace: return (UInt32(kVK_Space), UInt32(optionKey))
            case .ctrlOptionN: return (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
            case .ctrlOptionM: return (UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey))
            }
        }
    }

    /// `hoverDelay` < 0 = Thông minh: mở khi chuột chậm lại / dừng trên notch, lướt qua thì không.
    static let smartHover: Double = -1
    static let hoverDelays: [Double] = [smartHover, 0, 0.15, 0.3, 0.5]
    static func hoverDelayTitle(_ delay: Double) -> String {
        if delay < 0 { return L("Thông minh", "Smart") }
        return delay == 0 ? L("Không", "None") : String(format: "%.2g s", delay)
    }

    /// Kích thước notch khi mở: phóng cả nội dung quanh mép trên.
    enum ExpandedSize: String, CaseIterable, Identifiable {
        case compact, regular, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: return L("Gọn", "Compact")
            case .regular: return L("Vừa", "Regular")
            case .large: return L("Rộng", "Large")
            }
        }
        var scale: CGFloat {
            switch self {
            case .compact: return 0.88
            case .regular: return 1
            case .large: return 1.15
            }
        }
    }

    /// Nội dung một bên cánh notch lúc thu gọn. Tự động = ảnh bìa bên trái, sóng nhạc bên phải.
    enum WingItem: String, CaseIterable, Identifiable {
        case auto, artwork, equalizer, meeting, battery, clock, claude, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("Tự động", "Automatic")
            case .artwork: return L("Ảnh bìa", "Album art")
            case .equalizer: return L("Sóng nhạc", "Music bars")
            case .meeting: return L("Cuộc họp kế tiếp", "Next meeting")
            case .battery: return L("Pin", "Battery")
            case .clock: return L("Giờ", "Time")
            case .claude: return L("Mức dùng Claude", "Claude usage")
            case .none: return L("Trống", "Nothing")
            }
        }
    }

    enum AccentMode: String, CaseIterable, Identifiable {
        case artwork, fixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .artwork: return L("Theo ảnh bìa", "From album art")
            case .fixed: return L("Cố định", "Fixed")
            }
        }
    }

    /// Tab hiện ra khi mở notch.
    enum OpenTab: String, CaseIterable, Identifiable {
        case last, media, sound, tray, mirror, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .last: return L("Tab dùng lần trước", "Last used tab")
            case .media, .sound, .tray, .mirror, .system: return NotchModel.Tab(rawValue: rawValue)!.title
            }
        }
        var tab: NotchModel.Tab? { NotchModel.Tab(rawValue: rawValue) }
    }

    @Published var language: Language { didSet { save(language.rawValue, "language") } }
    @Published var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    @Published var openMode: OpenMode { didSet { save(openMode.rawValue, "openMode") } }
    /// Key mới "hoverDelay2": giá trị cũ (mặc định 0) không chặn chế độ Thông minh thành mặc định.
    @Published var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay2") } }
    @Published var hotkey: Hotkey { didSet { save(hotkey.rawValue, "hotkey") } }
    @Published var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "displayMode") } }
    @Published var noNotchStyle: NoNotchStyle { didSet { save(noNotchStyle.rawValue, "noNotchStyle") } }
    @Published var showMedia: Bool { didSet { save(showMedia, "tab.media") } }
    @Published var showCalendar: Bool { didSet { save(showCalendar, "tab.calendar") } }
    @Published var showTray: Bool { didSet { save(showTray, "tab.tray") } }
    @Published var showMirror: Bool { didSet { save(showMirror, "tab.mirror") } }
    @Published var showSound: Bool { didSet { save(showSound, "tab.sound") } }
    @Published var showSystem: Bool { didSet { save(showSystem, "tab.system") } }
    /// Tự gỡ file khỏi khay sau N ngày kể từ lúc thả vào; 0 = không bao giờ.
    @Published var trayExpiryDays: Int { didSet { save(trayExpiryDays, "trayExpiryDays") } }
    static let trayExpiryOptions = [0, 1, 7, 30]
    @Published var screenshotsToTray: Bool { didSet { save(screenshotsToTray, "screenshotsToTray") } }
    /// Mặc định tắt (key mới): bật lên macOS hiện chấm tím "đang ghi âm thanh hệ thống".
    @Published var realVisualizer: Bool { didSet { save(realVisualizer, "realVisualizer2") } }
    @Published var showPet: Bool { didSet { save(showPet, "showPet") } }
    @Published var expandedSize: ExpandedSize { didSet { save(expandedSize.rawValue, "expandedSize") } }
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }
    @Published var ambientGlow: Bool { didSet { save(ambientGlow, "ambientGlow") } }
    /// Notch không lọt vào chia sẻ / quay / chụp màn hình. Tắt mặc định để ảnh chụp màn hình vẫn có notch.
    @Published var hideInScreenShare: Bool {
        didSet {
            save(hideInScreenShare, "hideInScreenShare")
            for case let panel as NotchPanel in NSApp.windows { panel.applySharing() }
        }
    }
    @Published var autoMinimal: Bool { didSet { save(autoMinimal, "autoMinimal") } }
    @Published var powerSaver: Bool { didSet { save(powerSaver, "powerSaver") } }
    /// Lớp 1 của mở khoá bằng khuôn mặt: chỉ là hiệu ứng, chạy cả khi tính năng tắt.
    @Published var unlockEffect: Bool { didSet { save(unlockEffect, "unlockEffect") } }
    @Published var leftWing: WingItem { didSet { save(leftWing.rawValue, "wing.left") } }
    @Published var rightWing: WingItem { didSet { save(rightWing.rawValue, "wing.right") } }
    @Published var accentMode: AccentMode { didSet { save(accentMode.rawValue, "accentMode") } }
    /// Màu nhấn cố định, dạng "#RRGGBB".
    @Published var accentHex: String { didSet { save(accentHex, "accentHex") } }
    /// Thứ tự tab trên hàng tab (gồm cả tab đang tắt).
    @Published var tabOrder: [NotchModel.Tab] { didSet { save(tabOrder.map(\.rawValue), "tabOrder") } }
    @Published var openTab: OpenTab { didSet { save(openTab.rawValue, "openTab") } }
    /// Lời chào "hello" trên notch mỗi lần mở app (lần đầu luôn chào).
    @Published var welcomeOnLaunch: Bool { didSet { save(welcomeOnLaunch, "welcomeOnLaunch") } }

    private init() {
        let d = UserDefaults.standard
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .auto
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .standard
        openMode = OpenMode(rawValue: d.string(forKey: "openMode") ?? "") ?? .hover
        hoverDelay = d.object(forKey: "hoverDelay2") as? Double ?? Self.smartHover
        hotkey = Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .optionSpace
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .notch
        noNotchStyle = NoNotchStyle(rawValue: d.string(forKey: "noNotchStyle") ?? "") ?? .notch
        showMedia = d.object(forKey: "tab.media") as? Bool ?? true
        showCalendar = d.object(forKey: "tab.calendar") as? Bool ?? true
        showTray = d.object(forKey: "tab.tray") as? Bool ?? true
        showMirror = d.object(forKey: "tab.mirror") as? Bool ?? true
        showSound = d.object(forKey: "tab.sound") as? Bool ?? true
        showSystem = d.object(forKey: "tab.system") as? Bool ?? true
        trayExpiryDays = d.object(forKey: "trayExpiryDays") as? Int ?? 0
        screenshotsToTray = d.object(forKey: "screenshotsToTray") as? Bool ?? true
        realVisualizer = d.object(forKey: "realVisualizer2") as? Bool ?? false
        showPet = d.object(forKey: "showPet") as? Bool ?? true
        expandedSize = ExpandedSize(rawValue: d.string(forKey: "expandedSize") ?? "") ?? .regular
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        ambientGlow = d.object(forKey: "ambientGlow") as? Bool ?? true
        hideInScreenShare = d.bool(forKey: "hideInScreenShare")
        autoMinimal = d.object(forKey: "autoMinimal") as? Bool ?? true
        powerSaver = d.object(forKey: "powerSaver") as? Bool ?? true
        unlockEffect = d.object(forKey: "unlockEffect") as? Bool ?? true
        leftWing = WingItem(rawValue: d.string(forKey: "wing.left") ?? "") ?? .auto
        rightWing = WingItem(rawValue: d.string(forKey: "wing.right") ?? "") ?? .auto
        accentMode = AccentMode(rawValue: d.string(forKey: "accentMode") ?? "") ?? .artwork
        accentHex = d.string(forKey: "accentHex") ?? "#FF8A3D"
        var order = (d.stringArray(forKey: "tabOrder") ?? []).compactMap(NotchModel.Tab.init(rawValue:))
        order = order.enumerated().filter { order.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        // Tab mới (vd. Âm thanh) chèn ngay sau Nhạc, các tab còn thiếu khác thì nối cuối.
        if !order.isEmpty, !order.contains(.sound) { order.insert(.sound, at: (order.firstIndex(of: .media) ?? -1) + 1) }
        order += NotchModel.Tab.allCases.filter { !order.contains($0) }
        tabOrder = order
        openTab = OpenTab(rawValue: d.string(forKey: "openTab") ?? "") ?? .last
        welcomeOnLaunch = d.object(forKey: "welcomeOnLaunch") as? Bool ?? true
    }

    /// Màu nhấn cố định (nil = lấy theo ảnh bìa).
    var fixedAccent: Color? {
        accentMode == .fixed ? Color(hex: accentHex) : nil
    }

    func isEnabled(_ tab: NotchModel.Tab) -> Bool {
        switch tab {
        case .media: return showMedia || showCalendar
        case .tray: return showTray
        case .mirror: return showMirror
        case .sound: return showSound
        case .system: return showSystem
        }
    }

    func moveTab(at index: Int, by delta: Int) {
        let target = index + delta
        guard tabOrder.indices.contains(index), tabOrder.indices.contains(target) else { return }
        tabOrder.swapAt(index, target)
    }

    /// Các tab đang bật, theo thứ tự hiển thị.
    var enabledTabs: [NotchModel.Tab] { tabOrder.filter(isEnabled) }

    var isVietnamese: Bool { Lang.isVietnamese }
    var locale: Locale { Lang.locale }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

/// Ngôn ngữ đang dùng, đọc thẳng UserDefaults (gọi được từ mọi actor / thread).
enum Lang {
    static var isVietnamese: Bool {
        switch UserDefaults.standard.string(forKey: "language") ?? "auto" {
        case "vi": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("vi") ?? false
        }
    }

    static var locale: Locale { Locale(identifier: isVietnamese ? "vi_VN" : "en_US") }
}

/// Chuỗi theo ngôn ngữ đang chọn: L("Tiếng Việt", "English").
func L(_ vi: String, _ en: String) -> String {
    Lang.isVietnamese ? vi : en
}

extension Color {
    /// "#RRGGBB" → Color (sRGB). Sai định dạng → nil.
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
