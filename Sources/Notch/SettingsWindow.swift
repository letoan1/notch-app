import AppKit
import SwiftUI

/// Cửa sổ Cài đặt kiểu macOS: các tab trên thanh công cụ, cửa sổ co giãn theo nội dung từng tab.
/// (App dạng accessory không có menu bar → mở từ nút ⚙️ trên notch.)
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var languageSink: Any?

    func show() {
        let win = window ?? makeWindow()
        window = win
        relabel()
        NSApp.activate(ignoringOtherApps: true)
        if !win.isVisible { win.center() }
        win.makeKeyAndOrderFront(nil)
    }

    private enum Pane: Int, CaseIterable {
        case general, notch, tabs, tray, about

        var title: String {
            switch self {
            case .general: return L("Chung", "General")
            case .notch: return "Notch"
            case .tabs: return L("Tab", "Tabs")
            case .tray: return L("Khay file", "File tray")
            case .about: return L("Giới thiệu", "About")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .notch: return "macbook"
            case .tabs: return "square.grid.2x2"
            case .tray: return "tray.full"
            case .about: return "info.circle"
            }
        }

        @MainActor var view: AnyView {
            let s = SettingsStore.shared
            switch self {
            case .general: return AnyView(GeneralPane(settings: s))
            case .notch: return AnyView(NotchPane(settings: s))
            case .tabs: return AnyView(TabsPane(settings: s))
            case .tray: return AnyView(TrayPane(settings: s))
            case .about: return AnyView(AboutPane())
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for pane in Pane.allCases {
            let host = NSHostingController(rootView: pane.view)
            host.sizingOptions = .preferredContentSize
            host.title = pane.title   // tab chọn → tiêu đề cửa sổ
            let item = NSTabViewItem(viewController: host)
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs
        let win = NSWindow(contentViewController: tabs)
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.toolbarStyle = .preference
        win.isReleasedWhenClosed = false
        // Đổi ngôn ngữ: đặt lại tên tab + tiêu đề.
        languageSink = SettingsStore.shared.$language.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.relabel() }
        }
        return win
    }

    private func relabel() {
        guard let tabs else { return }
        for (i, pane) in Pane.allCases.enumerated() where i < tabs.tabViewItems.count {
            tabs.tabViewItems[i].label = pane.title
            tabs.tabViewItems[i].viewController?.title = pane.title
        }
        window?.title = Pane(rawValue: tabs.selectedTabViewItemIndex)?.title ?? L("Cài đặt Notch", "Notch Settings")
    }
}

/// Khung chung cho mỗi tab: Form nhóm, rộng cố định, cao theo nội dung.
private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Pane {
            Section {
                Picker(L("Ngôn ngữ", "Language"), selection: $settings.language) {
                    ForEach(SettingsStore.Language.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Giao diện", "Theme"), selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Kích thước khi mở", "Expanded size"), selection: $settings.expandedSize) {
                    ForEach(SettingsStore.ExpandedSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle(L("Thú cưng trên notch", "Notch pet"), isOn: $settings.showPet)
                Toggle(L("Rung nhẹ trên trackpad", "Trackpad haptics"), isOn: $settings.haptics)
            } footer: {
                Text(L("Trackpad Force Touch rung một nhịp khi notch mở và khi thả file vào khay.",
                       "Force Touch trackpads tap once when the notch opens and when a file lands in the tray."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NotchPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Pane {
            Section {
                Picker(L("Mở notch khi", "Open the notch on"), selection: $settings.openMode) {
                    ForEach(SettingsStore.OpenMode.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Độ trễ khi rê chuột", "Hover delay"), selection: $settings.hoverDelay) {
                    ForEach(SettingsStore.hoverDelays, id: \.self) { delay in
                        Text(delay == 0 ? L("Không", "None") : String(format: "%.2g s", delay)).tag(delay)
                    }
                }
                .disabled(settings.openMode != .hover)
                Picker(L("Phím tắt mở / đóng", "Toggle shortcut"), selection: $settings.hotkey) {
                    ForEach(SettingsStore.Hotkey.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker(L("Hiện trên", "Show on"), selection: $settings.displayMode) {
                    ForEach(SettingsStore.DisplayMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(L("Màn hình không có notch thật sẽ được vẽ một notch ở giữa mép trên.",
                       "Screens without a hardware notch get a drawn notch at the top center."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TabsPane: View {
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Pane {
            Section {
                Toggle(L("Nhạc (Spotify, Apple Music)", "Music (Spotify, Apple Music)"), isOn: $settings.showMedia)
                Toggle(L("Sóng nhạc theo âm thanh thật", "Live audio visualizer"), isOn: $settings.realVisualizer)
                    .disabled(!settings.showMedia)
            } footer: {
                Text(L("Sóng nhạc thật cần quyền Ghi âm thanh hệ thống; chỉ nghe Spotify/Music, không ghi lại.",
                       "The live visualizer needs System Audio Recording permission; it only listens to Spotify/Music and records nothing."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Lịch", "Calendar"), isOn: $settings.showCalendar)
                Toggle(L("Khay file", "File tray"), isOn: $settings.showTray)
                Toggle(L("Gương camera", "Camera mirror"), isOn: $settings.showMirror)
            }
        }
    }
}

private struct TrayPane: View {
    @ObservedObject var settings: SettingsStore

    private static func expiryTitle(_ days: Int) -> String {
        switch days {
        case 0: return L("Không bao giờ", "Never")
        case 1: return L("Sau 1 ngày", "After 1 day")
        default: return L("Sau \(days) ngày", "After \(days) days")
        }
    }

    var body: some View {
        Pane {
            Section {
                Toggle(L("Ảnh chụp màn hình tự vào khay", "Add screenshots to the tray"), isOn: $settings.screenshotsToTray)
                Picker(L("Tự dọn khay", "Auto-clear tray"), selection: $settings.trayExpiryDays) {
                    ForEach(SettingsStore.trayExpiryOptions, id: \.self) { days in
                        Text(Self.expiryTitle(days)).tag(days)
                    }
                }
            } footer: {
                Text(L("Khay chỉ giữ liên kết tới file gốc: di chuyển / đổi tên file vẫn còn trong khay; xoá file (hoặc bỏ vào Thùng rác) thì tự gỡ.",
                       "The tray keeps links to the original files: moved or renamed files stay in the tray; deleted (or trashed) files are removed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        Pane {
            Section {
                LabeledContent(L("Phiên bản", "Version"), value: version)
                Link("github.com/letoan1/notch-app", destination: URL(string: "https://github.com/letoan1/notch-app")!)
            }
            Section {
                Button(L("Thoát Notch", "Quit Notch"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
    }
}
