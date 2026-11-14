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
        case general, notch, tabs, tray, face, claude, about

        var title: String {
            switch self {
            case .general: return L("Chung", "General")
            case .notch: return "Notch"
            case .tabs: return L("Tab", "Tabs")
            case .tray: return L("Khay file", "File tray")
            case .face: return L("Khuôn mặt", "Face unlock")
            case .claude: return "Claude Code"
            case .about: return L("Giới thiệu", "About")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .notch: return "macbook"
            case .tabs: return "square.grid.2x2"
            case .tray: return "tray.full"
            case .face: return "faceid"
            case .claude: return "sparkle"
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
            case .face: return AnyView(FaceUnlockPane())
            case .claude: return AnyView(ClaudePane())
            case .about: return AnyView(AboutPane())
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let tabs = RememberingTabViewController()
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
        // Mở lại đúng tab lần trước.
        let last = UserDefaults.standard.integer(forKey: RememberingTabViewController.key)
        if Pane.allCases.indices.contains(last) { tabs.selectedTabViewItemIndex = last }
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
        window?.title = Pane(rawValue: tabs.selectedTabViewItemIndex)?.title ?? L("Cài đặt Roost", "Roost Settings")
    }
}

/// Nhớ tab Cài đặt đang chọn.
final class RememberingTabViewController: NSTabViewController {
    static let key = "settingsPane"
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.key)
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
                Picker(L("Màu nhấn", "Accent color"), selection: $settings.accentMode) {
                    ForEach(SettingsStore.AccentMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.accentMode == .fixed {
                    ColorPicker(L("Màu", "Color"), selection: Binding(
                        get: { Color(hex: settings.accentHex) ?? .orange },
                        set: { settings.accentHex = $0.hexString }), supportsOpacity: false)
                }
            } footer: {
                Text(L("Màu của thanh tiến độ, sóng nhạc và quầng sáng. Chọn theo ảnh bìa thì màu đổi theo từng bài.", "Used for the progress bar, the music bars and the glow. From album art changes it with every song."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Thú cưng trên notch", "Notch pet"), isOn: $settings.showPet)
                Toggle(L("Quầng sáng theo ảnh bìa", "Album-art glow"), isOn: $settings.ambientGlow)
                Toggle(L("Rung nhẹ trên trackpad", "Trackpad haptics"), isOn: $settings.haptics)
            } footer: {
                Text(L("Trackpad Force Touch rung nhẹ một nhịp khi notch mở ra và khi bạn thả file vào khay.", "Force Touch trackpads give a light tap when the notch opens and when you drop a file into the tray."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Tối giản khi toàn màn hình", "Minimal in full screen"), isOn: $settings.autoMinimal)
                Toggle(L("Tự tiết kiệm pin", "Battery saver"), isOn: $settings.powerSaver)
            } footer: {
                Text(L("Khi một app chạy toàn màn hình (video, game, trình chiếu), notch ẩn cánh và thú cưng, còn notch vẽ trên màn rời thì ẩn hẳn. Rê chuột lúc đó không mở notch, nhưng phím tắt và yêu cầu của Claude vẫn mở được. Khi bật Low Power Mode hoặc pin dưới 20%, app tắt sóng nhạc thật, thú cưng và quầng sáng.", "When an app is full screen (video, games, slides), the notch hides its wings and the pet, and drawn notches on other screens disappear. Hovering won't open it then, but the shortcut and Claude requests still will. In Low Power Mode or below 20% battery, the app turns off the live visualizer, the pet and the glow."))
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
                        Text(SettingsStore.hoverDelayTitle(delay)).tag(delay)
                    }
                }
                .disabled(settings.openMode != .hover)
                    .help(L("Thông minh: notch mở khi con trỏ chậm lại hoặc dừng ở đó. Lướt nhanh qua để bấm icon trên thanh menu thì notch không mở.", "Smart: the notch opens when the pointer slows down or rests on it. Sweeping past it to reach a menu bar icon won't open it."))
                Picker(L("Phím tắt mở / đóng", "Toggle shortcut"), selection: $settings.hotkey) {
                    ForEach(SettingsStore.Hotkey.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker(L("Bên trái", "Left side"), selection: $settings.leftWing) {
                    ForEach(SettingsStore.WingItem.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Bên phải", "Right side"), selection: $settings.rightWing) {
                    ForEach(SettingsStore.WingItem.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L("Hai bên notch khi thu gọn", "Beside the closed notch"))
            } footer: {
                Text(L("Tự động: ảnh bìa bên trái, sóng nhạc bên phải, chỉ khi có nhạc. Giờ, pin và cuộc họp hiện cả khi không phát nhạc. Cuộc họp chỉ hiện khi còn dưới 2 giờ nữa là bắt đầu. Thông báo nhanh (cắm sạc, tai nghe, ảnh chụp) vẫn hiện đè lên.", "Automatic: album art on the left, music bars on the right, only while music is playing. Time, battery and meetings show even without music. A meeting shows once it starts within 2 hours. Quick alerts (charging, headphones, screenshots) still take over."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("Hiện trên", "Show on"), selection: $settings.displayMode) {
                    ForEach(SettingsStore.DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Màn hình không có notch", "Screens without a notch"), selection: $settings.noNotchStyle) {
                    ForEach(SettingsStore.NoNotchStyle.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(L("Màn hình không có notch thật sẽ có một notch vẽ ở giữa mép trên, hoặc một viên bo tròn nổi ngay dưới mép (giống Dynamic Island). Màn hình có notch thật luôn giữ hình notch.", "Screens without a hardware notch get a drawn notch at the top center, or a rounded pill floating just below the edge (like the Dynamic Island). Screens with a real notch always keep the notch shape."))
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
                Toggle(L("Nhạc (mọi app: Spotify, Music, trình duyệt…)", "Music (any app: Spotify, Music, browsers…)"), isOn: $settings.showMedia)
                Toggle(L("Sóng nhạc theo âm thanh thật", "Live audio visualizer"), isOn: $settings.realVisualizer)
                    .disabled(!settings.showMedia)
            } footer: {
                Text(L("Cần quyền \"Chỉ ghi âm thanh hệ thống\". App chỉ nghe app đang phát nhạc, không ghi lại và không đụng tới loa hay tai nghe. Khi bật, macOS hiện chấm tím trên thanh menu lúc đang phát nhạc. Khi tắt, cột sóng nhảy theo hiệu ứng có sẵn.", "Needs the \"System Audio Recording Only\" permission. Roost only listens to the app that is playing, records nothing and leaves your speakers and headphones alone. While it is on, macOS shows a purple dot in the menu bar during playback. When it is off, the bars use a built-in animation."))
                    .font(.caption).foregroundStyle(.secondary)
                if settings.realVisualizer {
                    HStack(spacing: 6) {
                        Text(L("Sóng vẫn nhảy đều dù đang phát nhạc? Có thể quyền đã bị tắt.", "Bars still look generic while music plays? The permission may be off."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane("Privacy_AudioCapture") }
                            .controlSize(.small)
                    }
                }
            }
            Section {
                Toggle(L("Lịch", "Calendar"), isOn: $settings.showCalendar)
                Toggle(L("Khay file", "File tray"), isOn: $settings.showTray)
                Toggle(L("Gương camera", "Camera mirror"), isOn: $settings.showMirror)
            }
            Section {
                ForEach(Array(settings.tabOrder.enumerated()), id: \.element) { index, tab in
                    HStack(spacing: 8) {
                        Image(systemName: tab.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(tab.title)
                        if !settings.isEnabled(tab) {
                            Text(L("đang tắt", "off")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { settings.moveTab(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help(L("Lên trước", "Move left"))
                        Button { settings.moveTab(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == settings.tabOrder.count - 1)
                            .help(L("Ra sau", "Move right"))
                    }
                    .buttonStyle(.borderless)
                    .opacity(settings.isEnabled(tab) ? 1 : 0.55)
                }
                Picker(L("Khi mở notch, hiện", "When the notch opens, show"), selection: $settings.openTab) {
                    ForEach(SettingsStore.OpenTab.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L("Thứ tự tab", "Tab order"))
            } footer: {
                Text(L("Tab trên cùng đứng đầu hàng tab. Kéo file vào notch vẫn luôn mở khay, và thẻ của Claude vẫn hiện trước mọi tab.", "The top tab comes first in the tab bar. Dragging a file onto the notch still opens the tray, and Claude cards still show before any tab."))
                    .font(.caption).foregroundStyle(.secondary)
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
                Text(L("Khay chỉ giữ liên kết tới file gốc. Bạn di chuyển hay đổi tên file thì file vẫn còn trong khay; xoá file hoặc bỏ vào Thùng rác thì file tự rời khỏi khay.", "The tray only keeps links to the original files. Moving or renaming a file keeps it in the tray; deleting it or moving it to the Trash removes it."))
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
                Button(L("Mở hướng dẫn cài đặt", "Open the setup guide")) { OnboardingWindowController.shared.show() }
            }
            Section {
                Button(L("Thoát Roost", "Quit Roost"), role: .destructive) { NSApp.terminate(nil) }
            }
        }
    }
}
