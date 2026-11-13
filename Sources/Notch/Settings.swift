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

    static let hoverDelays: [Double] = [0, 0.15, 0.3, 0.5]

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

    @Published var language: Language { didSet { save(language.rawValue, "language") } }
    @Published var theme: Theme { didSet { save(theme.rawValue, "theme") } }
    @Published var openMode: OpenMode { didSet { save(openMode.rawValue, "openMode") } }
    @Published var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    @Published var hotkey: Hotkey { didSet { save(hotkey.rawValue, "hotkey") } }
    @Published var displayMode: DisplayMode { didSet { save(displayMode.rawValue, "displayMode") } }
    @Published var showMedia: Bool { didSet { save(showMedia, "tab.media") } }
    @Published var showCalendar: Bool { didSet { save(showCalendar, "tab.calendar") } }
    @Published var showTray: Bool { didSet { save(showTray, "tab.tray") } }
    @Published var showMirror: Bool { didSet { save(showMirror, "tab.mirror") } }
    /// Tự gỡ file khỏi khay sau N ngày kể từ lúc thả vào; 0 = không bao giờ.
    @Published var trayExpiryDays: Int { didSet { save(trayExpiryDays, "trayExpiryDays") } }
    static let trayExpiryOptions = [0, 1, 7, 30]
    @Published var screenshotsToTray: Bool { didSet { save(screenshotsToTray, "screenshotsToTray") } }
    @Published var realVisualizer: Bool { didSet { save(realVisualizer, "realVisualizer") } }
    @Published var showPet: Bool { didSet { save(showPet, "showPet") } }
    @Published var expandedSize: ExpandedSize { didSet { save(expandedSize.rawValue, "expandedSize") } }
    @Published var haptics: Bool { didSet { save(haptics, "haptics") } }

    private init() {
        let d = UserDefaults.standard
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .auto
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .standard
        openMode = OpenMode(rawValue: d.string(forKey: "openMode") ?? "") ?? .hover
        hoverDelay = d.object(forKey: "hoverDelay") as? Double ?? 0
        hotkey = Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .optionSpace
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .notch
        showMedia = d.object(forKey: "tab.media") as? Bool ?? true
        showCalendar = d.object(forKey: "tab.calendar") as? Bool ?? true
        showTray = d.object(forKey: "tab.tray") as? Bool ?? true
        showMirror = d.object(forKey: "tab.mirror") as? Bool ?? true
        trayExpiryDays = d.object(forKey: "trayExpiryDays") as? Int ?? 0
        screenshotsToTray = d.object(forKey: "screenshotsToTray") as? Bool ?? true
        realVisualizer = d.object(forKey: "realVisualizer") as? Bool ?? true
        showPet = d.object(forKey: "showPet") as? Bool ?? true
        expandedSize = ExpandedSize(rawValue: d.string(forKey: "expandedSize") ?? "") ?? .regular
        haptics = d.object(forKey: "haptics") as? Bool ?? true
    }

    /// Các tab đang bật, theo thứ tự hiển thị.
    var enabledTabs: [NotchModel.Tab] {
        var tabs: [NotchModel.Tab] = []
        if showMedia || showCalendar { tabs.append(.media) }
        if showTray { tabs.append(.tray) }
        if showMirror { tabs.append(.mirror) }
        return tabs
    }

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
