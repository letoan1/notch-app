import AppKit
import SwiftUI
import FaceUnlockKit

/// Cửa sổ Cài đặt: thanh bên chia nhóm (icon màu) bên trái, trang cuộn bên phải.
/// (App dạng accessory không có menu bar → mở từ nút Cài đặt trên notch.)
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    let nav = SettingsNav()

    func show() {
        let win = window ?? makeWindow()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        if !win.isVisible { win.center() }
        win.makeKeyAndOrderFront(nil)
    }

    /// Mở thẳng một mục (vd. "claude" khi chưa bật mức dùng).
    func show(pane id: String) {
        if let pane = PaneID(rawValue: id) { nav.selection = pane }
        show()
    }

    /// id dạng chuỗi để thêm / bớt mục không làm lệch mục đã nhớ.
    enum PaneID: String, CaseIterable, Identifiable {
        case general, appearance, music, sound, calendar, tray, mirror, claude, usage, alerts, awake, pet, face, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return L("Chung", "General")
            case .appearance: return L("Giao diện", "Appearance")
            case .music: return L("Nhạc", "Music")
            case .sound: return L("Âm thanh", "Sound")
            case .calendar: return L("Lịch", "Calendar")
            case .tray: return L("Khay file", "File tray")
            case .mirror: return L("Gương", "Mirror")
            case .claude: return "Claude Code"
            case .usage: return L("Mức dùng Claude", "Claude usage")
            case .alerts: return L("Thông báo", "Alerts")
            case .awake: return L("Giữ máy thức", "Keep awake")
            case .pet: return L("Thú cưng", "Pet")
            case .face: return L("Khuôn mặt", "Face unlock")
            case .about: return L("Giới thiệu", "About")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .appearance: return "paintpalette.fill"
            case .music: return "music.note"
            case .sound: return "speaker.wave.2.fill"
            case .calendar: return "calendar"
            case .tray: return "tray.full.fill"
            case .mirror: return "camera.fill"
            case .claude: return "sparkle"
            case .usage: return "gauge.with.dots.needle.67percent"
            case .alerts: return "bell.badge.fill"
            case .awake: return "cup.and.saucer.fill"
            case .pet: return "pawprint.fill"
            case .face: return "faceid"
            case .about: return "info"
            }
        }

        var tint: Color {
            switch self {
            case .general: return Color(red: 0.55, green: 0.57, blue: 0.62)
            case .appearance: return Color(red: 0.2, green: 0.52, blue: 0.98)
            case .music: return Color(red: 0.98, green: 0.27, blue: 0.4)
            case .sound: return Color(red: 0.95, green: 0.45, blue: 0.2)
            case .calendar: return Color(red: 0.95, green: 0.3, blue: 0.27)
            case .tray: return Color(red: 0.2, green: 0.74, blue: 0.4)
            case .mirror: return Color(red: 0.16, green: 0.68, blue: 0.78)
            case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
            case .usage: return Color(red: 0.6, green: 0.42, blue: 0.95)
            case .alerts: return Color(red: 1, green: 0.62, blue: 0.1)
            case .awake: return Color(red: 0.62, green: 0.43, blue: 0.3)
            case .pet: return Color(red: 0.36, green: 0.42, blue: 0.95)
            case .face: return Color(red: 0.14, green: 0.6, blue: 0.95)
            case .about: return Color(red: 0.55, green: 0.57, blue: 0.62)
            }
        }

        @MainActor @ViewBuilder var view: some View {
            let s = SettingsStore.shared
            switch self {
            case .general: GeneralPane(settings: s)
            case .appearance: AppearancePane(settings: s)
            case .music: MusicPane(settings: s)
            case .sound: SoundPane(settings: s)
            case .calendar: CalendarPane(settings: s)
            case .tray: TrayPane(settings: s)
            case .mirror: MirrorPane(settings: s)
            case .claude: ClaudePane()
            case .usage: ClaudeUsagePane()
            case .alerts: AlertsPane()
            case .awake: KeepAwakePane()
            case .pet: PetPane(settings: s)
            case .face: FaceUnlockPane()
            case .about: AboutPane()
            }
        }

        /// Các nhóm trên thanh bên (nhóm đầu không có tiêu đề).
        static var groups: [(String?, [PaneID])] {
            [(nil, [.general, .appearance]),
             (L("Tính năng", "Features"), [.music, .sound, .calendar, .tray, .mirror, .claude, .usage]),
             (L("Trải nghiệm", "Experiences"), [.alerts, .awake, .pet, .face]),
             (L("Khác", "Other"), [.about])]
        }

        /// Mục đã nhớ. Bản cũ lưu id kiểu khác ("tabs") hoặc số thứ tự.
        static var remembered: PaneID {
            let d = UserDefaults.standard
            if let raw = d.string(forKey: SettingsNav.key) {
                if let id = PaneID(rawValue: raw) { return id }
                if raw == "tabs" { return .music }
            }
            guard d.object(forKey: SettingsNav.legacyKey) != nil else { return .general }
            let old: [PaneID] = [.general, .general, .music, .tray, .alerts, .face, .claude, .about]
            let i = d.integer(forKey: SettingsNav.legacyKey)
            d.removeObject(forKey: SettingsNav.legacyKey)
            return old.indices.contains(i) ? old[i] : .general
        }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsRoot(nav: nav, settings: SettingsStore.shared))
        host.sizingOptions = []
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = L("Cài đặt Roost", "Roost Settings")
        win.isMovableByWindowBackground = true
        // Toolbar rỗng kiểu unified: thanh tiêu đề cao 52 pt, 3 nút cửa sổ hạ xuống nằm gọn trong thẻ thanh bên,
        // ngang hàng tiêu đề trang. Tự đúng khi đổi cỡ, toàn màn hình và chế độ tối.
        let bar = NSToolbar(identifier: "roost.settings")
        bar.showsBaselineSeparator = false
        win.toolbar = bar
        win.toolbarStyle = .unified
        win.titlebarSeparatorStyle = .none
        win.setContentSize(SUI.windowSize)
        win.contentMinSize = CGSize(width: 820, height: 560)
        win.isReleasedWhenClosed = false
        return win
    }
}

/// Nút thoát đỏ góc phải: nền trắng nổi, rê chuột thì đỏ đặc.
private struct SQuitButton: View {
    private var hover = State(initialValue: false)
    var body: some View {
        let red = Color(red: 0.92, green: 0.25, blue: 0.24)
        Button { NSApp.terminate(nil) } label: {
            Image(systemName: "power")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(hover.wrappedValue ? Color.white : red)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hover.wrappedValue ? red : Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(hover.wrappedValue ? 0 : 0.1)))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.wrappedValue)
        .help(L("Thoát Roost", "Quit Roost"))
    }
}

/// Mục đang chọn, nhớ theo id chuỗi.
@MainActor
final class SettingsNav: ObservableObject {
    nonisolated static let key = "settingsPaneID"
    nonisolated static let legacyKey = "settingsPane"
    @Published var selection: SettingsWindowController.PaneID = SettingsWindowController.PaneID.remembered {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: Self.key) }
    }
}

private struct SettingsRoot: View {
    @ObservedObject var nav: SettingsNav
    @ObservedObject var settings: SettingsStore   // đổi ngôn ngữ → dựng lại chữ

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(nav.selection.title).font(.system(size: 22, weight: .semibold))
                    Spacer()
                    SQuitButton()
                }
                .padding(.horizontal, 28)
                .frame(height: 52)
                .padding(.top, 2)
                .padding(.bottom, 6)
                nav.selection.view
                    .id(nav.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .buttonStyle(SButtonStyle(.secondary))
        .environment(\.locale, settings.locale)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(SettingsWindowController.PaneID.groups.enumerated()), id: \.offset) { _, group in
                    if let title = group.0 {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }
                    ForEach(group.1) { pane in
                        SSidebarItem(pane: pane, selected: nav.selection == pane) { nav.selection = pane }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 42)   // chừa chỗ cho 3 nút cửa sổ (tâm cách mép trên cửa sổ 26 pt)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.automatic)
        // Cuộn gọn trong thẻ: mục cuối không bị cắt ngang ở góc bo khi cửa sổ thấp.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
        )
        .padding(8)
        .frame(width: SUI.sidebarWidth)
    }
}

// MARK: - Chung

private struct GeneralPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SPage {
            SSection(L("Ngôn ngữ", "Language")) {
                SRow("globe", L("Ngôn ngữ của Roost", "Roost language"),
                     detail: L("Tự động theo ngôn ngữ của macOS.", "Automatic follows your macOS language."), divider: false) {
                    SPicker($settings.language, Array(SettingsStore.Language.allCases), title: { $0.title })
                }
            }
            SSection(L("Mở notch", "Opening the notch"),
                     note: L("Thông minh: notch chỉ mở khi con trỏ chậm lại hoặc dừng ở đó, lướt qua để bấm thanh menu thì không mở.",
                             "Smart: the notch only opens when the pointer slows down or rests on it, so sweeping past to the menu bar won't open it."),
                     reset: resetOpening) {
                SRow("cursorarrow.click.2", L("Mở notch khi", "Open the notch on"), divider: false) {
                    SPicker($settings.openMode, Array(SettingsStore.OpenMode.allCases), title: { $0.title })
                }
                SRow("timer", L("Độ trễ khi rê chuột", "Hover delay"),
                     detail: L("Chỉ dùng khi mở bằng cách rê chuột.", "Only used when opening on hover.")) {
                    SPicker($settings.hoverDelay, Array(SettingsStore.hoverDelays), title: { SettingsStore.hoverDelayTitle($0) })
                    .disabled(settings.openMode != .hover)
                }
                SRow("command", L("Phím tắt mở và đóng", "Toggle shortcut"),
                     detail: L("Không cần quyền Trợ năng.", "Needs no Accessibility access.")) {
                    SPicker($settings.hotkey, Array(SettingsStore.Hotkey.allCases), title: { $0.title })
                }
                SToggleRow(icon: "hand.tap", title: L("Rung nhẹ trên trackpad", "Trackpad haptics"),
                           detail: L("Một nhịp rung khi notch mở và khi bạn thả file vào khay.", "A tap when the notch opens and when you drop a file."),
                           isOn: $settings.haptics)
            }
            SSection(L("Màn hình", "Displays"),
                     note: L("Màn hình không có notch thật sẽ có một notch vẽ ở giữa mép trên, hoặc một viên bo tròn nổi ngay dưới mép.",
                             "Screens without a hardware notch get a drawn notch at the top center, or a rounded pill floating just below the edge."),
                     reset: { settings.displayMode = .notch; settings.noNotchStyle = .notch }) {
                SRow("display.2", L("Hiện trên", "Show on"), divider: false) {
                    SPicker($settings.displayMode, Array(SettingsStore.DisplayMode.allCases), title: { $0.title })
                }
                SRow("rectangle.topthird.inset.filled", L("Màn hình không có notch", "Screens without a notch")) {
                    SPicker($settings.noNotchStyle, Array(SettingsStore.NoNotchStyle.allCases), title: { $0.title })
                }
            }
            SSection(L("Hiệu năng", "Performance"),
                     reset: { settings.autoMinimal = true; settings.powerSaver = true }) {
                SToggleRow(icon: "arrow.down.right.and.arrow.up.left", title: L("Tối giản khi toàn màn hình", "Minimal in full screen"),
                           detail: L("Ẩn cánh và thú cưng, rê chuột không mở notch. Phím tắt và Claude vẫn mở được.",
                                     "Hides the wings and pet; hovering won't open it, but the shortcut and Claude still will."),
                           divider: false, isOn: $settings.autoMinimal)
                SToggleRow(icon: "leaf", title: L("Tự tiết kiệm pin", "Battery saver"),
                           detail: L("Khi bật Low Power Mode hoặc pin dưới 20%, tắt sóng nhạc thật, thú cưng và quầng sáng.",
                                     "In Low Power Mode or below 20% battery, turns off the live visualizer, the pet and the glow."),
                           isOn: $settings.powerSaver)
            }
        }
    }

    private func resetOpening() {
        settings.openMode = .hover
        settings.hoverDelay = SettingsStore.smartHover
        settings.hotkey = .optionSpace
        settings.haptics = true
    }
}

// MARK: - Giao diện

private struct AppearancePane: View {
    @ObservedObject var settings: SettingsStore
    private var dragging = State<NotchModel.Tab?>(initialValue: nil)

    init(settings: SettingsStore) { self.settings = settings }

    var body: some View {
        SPage {
            SSection(L("Giao diện", "Theme"),
                     note: L("Mỗi giao diện có cách hiển thị riêng cho từng tab và một thú cưng riêng.",
                             "Each theme has its own take on every tab and its own pet.")) {
                SBlock(divider: false) {
                    HStack(spacing: 12) {
                        ForEach(Theme.allCases) { theme in
                            SChoiceCard(title: theme.title, selected: settings.theme == theme, height: 74,
                                        action: { settings.theme = theme }) {
                                ThemeSwatch(theme: theme)
                            }
                        }
                    }
                }
                SRow("arrow.up.left.and.arrow.down.right", L("Kích thước khi mở", "Expanded size")) {
                    SSegmented($settings.expandedSize, Array(SettingsStore.ExpandedSize.allCases), title: { $0.title })
                    .frame(width: 210)
                }
            }
            SSection(L("Màu", "Color"),
                     note: L("Màu nhấn dùng cho thanh tiến độ, sóng nhạc và quầng sáng. Theo ảnh bìa thì màu đổi theo từng bài.",
                             "The accent colors the progress bar, the music bars and the glow. From album art changes it with every song."),
                     reset: { settings.accentMode = .artwork; settings.accentHex = "#FF8A3D"; settings.ambientGlow = true }) {
                SRow("paintbrush", L("Màu nhấn", "Accent color"), divider: false) {
                    HStack(spacing: 10) {
                        if settings.accentMode == .fixed {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: settings.accentHex) ?? .orange },
                                set: { settings.accentHex = $0.hexString }), supportsOpacity: false)
                        }
                        SSegmented($settings.accentMode, Array(SettingsStore.AccentMode.allCases), title: { $0.title })
                        .frame(width: 200)
                    }
                }
                SToggleRow(icon: "sun.max", title: L("Quầng sáng theo ảnh bìa", "Album-art glow"),
                           detail: L("Ánh màu ảnh bìa toả ra quanh notch thu gọn.", "The album colors glow around the closed notch."),
                           isOn: $settings.ambientGlow)
            }
            SSection(L("Hai bên notch khi thu gọn", "Beside the closed notch"),
                     note: L("Tự động: ảnh bìa bên trái, sóng nhạc bên phải, chỉ khi có nhạc. Giờ, pin và cuộc họp hiện cả khi không có nhạc.",
                             "Automatic: album art on the left and music bars on the right, only while music plays. Time, battery and meetings show without music."),
                     reset: { settings.leftWing = .auto; settings.rightWing = .auto }) {
                SBlock(divider: false) {
                    WingPreview(left: settings.leftWing, right: settings.rightWing)
                        .frame(height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                SRow("rectangle.lefthalf.inset.filled", L("Bên trái", "Left side")) {
                    SPicker($settings.leftWing, Array(SettingsStore.WingItem.allCases), title: { $0.title })
                }
                SRow("rectangle.righthalf.inset.filled", L("Bên phải", "Right side")) {
                    SPicker($settings.rightWing, Array(SettingsStore.WingItem.allCases), title: { $0.title })
                }
            }
            SSection(L("Bố cục notch", "Notch layout"),
                     note: L("Nút Cài đặt luôn ở cuối thanh công cụ (chuột phải để thoát). Mục để ở Chưa dùng thì không hiện trên notch.",
                             "The Settings button always sits at the end of the toolbar (right-click to quit). Items left in Not in use don't appear on the notch.")) {
                SBlock(divider: false) { NotchLayoutEditor() }
            }
            SSection(L("Tab trên notch", "Notch tabs"),
                     note: L("Kéo chip để đổi thứ tự, bấm ô tròn để ẩn hay hiện một tab. Kéo file vào notch vẫn luôn mở khay, thẻ của Claude luôn hiện trước mọi tab.",
                             "Drag a chip to reorder and click its circle to hide or show a tab. Dropping a file still opens the tray, and Claude cards always come first."),
                     reset: { settings.tabOrder = NotchModel.Tab.allCases; settings.openTab = .last }) {
                SBlock(divider: false) {
                    // Lưới tự xuống dòng: đủ chỗ cho tên tab dài (Nhạc và lịch, Âm thanh…) ở mọi cỡ cửa sổ.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(settings.tabOrder, id: \.self) { tab in
                            TabChip(tab: tab, on: enabled(tab), dragging: dragging.wrappedValue == tab)
                                .onDrag {
                                    dragging.wrappedValue = tab
                                    return NSItemProvider(object: tab.rawValue as NSString)
                                }
                                .onDrop(of: [.text], delegate: SReorderDrop(item: tab, items: $settings.tabOrder,
                                                                            dragging: dragging.projectedValue))
                        }
                    }
                }
                SRow("rectangle.portrait.and.arrow.forward", L("Khi mở notch, hiện", "When the notch opens, show")) {
                    SPicker($settings.openTab, Array(SettingsStore.OpenTab.allCases), title: { $0.title })
                }
            }
        }
    }

    private func enabled(_ tab: NotchModel.Tab) -> Binding<Bool> {
        switch tab {
        case .media:
            // Tab này gồm cả nhạc lẫn lịch: bật lại thì bật cả hai.
            return Binding(get: { settings.showMedia || settings.showCalendar },
                           set: { settings.showMedia = $0; settings.showCalendar = $0 })
        case .tray: return $settings.showTray
        case .mirror: return $settings.showMirror
        case .sound: return $settings.showSound
        case .system: return $settings.showSystem
        }
    }
}

/// Chip một tab: kéo để đổi chỗ, ô tròn để bật / tắt.
private struct TabChip: View {
    let tab: NotchModel.Tab
    @Binding var on: Bool
    let dragging: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
            Text(tab.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button { on.toggle() } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? SUI.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(on ? L("Ẩn tab này", "Hide this tab") : L("Hiện tab này", "Show this tab"))
        }
        .opacity(on ? 1 : 0.55)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(dragging ? SUI.accent : Color.primary.opacity(0.1), lineWidth: dragging ? 1.5 : 1))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

/// Notch thu gọn trên nền giả desktop, hai bên hiện đúng thứ đã chọn.
private struct WingPreview: View {
    let left: SettingsStore.WingItem
    let right: SettingsStore.WingItem

    var body: some View {
        ZStack(alignment: .top) {
            SWallpaper()
            HStack(spacing: 0) {
                wing(left, leading: true)
                Color.black.frame(width: 120)
                wing(right, leading: false)
            }
            .frame(height: 30)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black))
        }
    }

    private func wing(_ item: SettingsStore.WingItem, leading: Bool) -> some View {
        let auto = leading ? SettingsStore.WingItem.artwork : .equalizer
        let shown = item == .auto ? auto : item
        return Group {
            switch shown {
            case .artwork:
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 18)
            case .equalizer:
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach([7, 12, 6, 10], id: \.self) { Capsule().fill(Color.orange).frame(width: 3, height: CGFloat($0)) }
                }
            case .meeting: label("video.fill", "12p")
            case .battery: label("battery.75percent", "76%")
            case .clock: Text("9:41").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            case .claude: label("gauge.with.dots.needle.67percent", "29%")
            case .none, .auto: Color.clear
            }
        }
        .frame(width: 64)
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.white)
    }
}

/// Hình nhỏ gợi tả từng giao diện (vẽ tĩnh, không chạy hiệu ứng).
struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        switch theme {
        case .standard:
            ZStack {
                SWallpaper()
                notch(fill: .black) {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                            .frame(width: 11, height: 11)
                        Spacer()
                        bars(Color(red: 1, green: 0.55, blue: 0.3))
                    }
                }
            }
        case .pixel:
            ZStack {
                Color(red: 0.11, green: 0.09, blue: 0.22)
                notch(fill: Color(red: 0.16, green: 0.13, blue: 0.3), corner: 0) {
                    HStack(spacing: 0) {
                        Rectangle().fill(Color(red: 1, green: 0.42, blue: 0.62)).frame(width: 10, height: 10)
                        Spacer()
                        HStack(alignment: .bottom, spacing: 1.5) {
                            ForEach([5, 9, 6, 11], id: \.self) { h in
                                Rectangle().fill(Color(red: 0.45, green: 0.95, blue: 0.55)).frame(width: 3, height: CGFloat(h))
                            }
                        }
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle().strokeBorder(Color(red: 1, green: 0.42, blue: 0.62), lineWidth: 1.5).frame(width: 80, height: 22)
                }
            }
        case .cassette:
            ZStack {
                Color(red: 0.84, green: 0.76, blue: 0.62)
                notch(fill: Color(red: 0.2, green: 0.17, blue: 0.14)) {
                    HStack(spacing: 6) {
                        ForEach(0..<2, id: \.self) { _ in
                            Circle().strokeBorder(Color(red: 0.95, green: 0.88, blue: 0.75), lineWidth: 2).frame(width: 10, height: 10)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        case .vangogh:
            ZStack {
                Color(red: 0.12, green: 0.2, blue: 0.5)
                    .overlay {
                        if let panel = VG.panel {
                            Image(nsImage: panel).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipped()
                notch(fill: .black) {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2).fill(VG.yellow).frame(width: 11, height: 11)
                        Spacer()
                        bars(VG.yellow)
                    }
                }
            }
        }
    }

    private func notch<C: View>(fill: Color, corner: CGFloat = 7, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner)
                .fill(fill)
                .frame(width: 80, height: 22)
                .overlay(content().padding(.horizontal, 6))
            Spacer(minLength: 0)
        }
    }

    private func bars(_ color: Color) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach([6, 10, 5, 8], id: \.self) { h in
                Capsule().fill(color).frame(width: 2.5, height: CGFloat(h))
            }
        }
    }
}

// MARK: - Nhạc

private struct MusicPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var lock = LockScreenMusic.shared
    @ObservedObject var lyrics = LyricsStore.shared

    var body: some View {
        SPage {
            SSection(L("Trình phát", "Player"),
                     note: L("Sóng nhạc thật cần quyền \"Chỉ ghi âm thanh hệ thống\": Roost chỉ nghe app đang phát, không ghi lại gì. Khi bật, macOS hiện chấm tím trên thanh menu lúc đang phát.",
                             "The live visualizer needs the \"System Audio Recording Only\" permission: Roost only listens to the playing app and records nothing. While on, macOS shows a purple dot in the menu bar during playback.")) {
                SToggleRow(icon: "music.note", title: L("Trình phát nhạc trên notch", "Music player on the notch"),
                           detail: L("Spotify, Apple Music, trình duyệt và mọi app phát nhạc.", "Spotify, Apple Music, browsers and any app that plays audio."),
                           divider: false, isOn: $settings.showMedia)
                SToggleRow(icon: "app.badge", title: L("Hiện icon ứng dụng phát nhạc", "Show the playing app's icon"),
                           detail: L("Huy hiệu nhỏ ở góc ảnh bìa, bấm vào để mở app đó.", "A small badge on the artwork corner. Click it to open that app."),
                           isOn: Binding(get: { UserDefaults.standard.object(forKey: SourceAppIcon.key) as? Bool ?? true },
                                         set: { UserDefaults.standard.set($0, forKey: SourceAppIcon.key); settings.objectWillChange.send() }))
                    .disabled(!settings.showMedia)
                SToggleRow(icon: "waveform", title: L("Sóng nhạc theo âm thanh thật", "Live audio visualizer"),
                           detail: L("Cột sóng chạy theo âm thanh đang phát. Tốn pin hơn một chút.", "Bars follow the audio that is playing. Uses a little more energy."),
                           isOn: $settings.realVisualizer)
                    .disabled(!settings.showMedia)
                if settings.realVisualizer {
                    SRow("lock.shield", L("Quyền ghi âm thanh hệ thống", "System audio permission")) {
                        Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane("Privacy_AudioCapture") }
                            .controlSize(.small)
                    }
                }
            }
            SSection(L("Lời bài hát", "Lyrics"),
                     note: L("Lời chỉ có với Spotify và Apple Music. Roost gửi tên bài, ca sĩ, album và độ dài bài tới lrclib.net để lấy lời, rồi lưu lại trên máy.",
                             "Lyrics work with Spotify and Apple Music only. Roost sends the song title, artist, album and length to lrclib.net, then keeps a copy on this Mac.")) {
                SToggleRow(icon: "quote.bubble", title: L("Lời bài hát (LRCLIB)", "Lyrics (LRCLIB)"),
                           detail: L("Nút lời trong trình phát, lời chạy theo nhạc và chế độ toàn màn hình.", "A lyrics button in the player, synced lines and a full-screen view."),
                           divider: false, isOn: $lyrics.enabled)
                    .disabled(!settings.showMedia)
            }
            SSection(L("Trên màn hình khoá", "On the lock screen"),
                     note: L("Trình phát chỉ có khi máy đang khoá, cất đi ngay khi mở khoá và khi màn hình tắt.",
                             "The player only exists while the Mac is locked and goes away on unlock or when the display sleeps."),
                     reset: { lock.style = .compact; lock.mode = .playing }) {
                SBlock(divider: false) {
                    HStack(spacing: 12) {
                        ForEach(LockScreenMusic.Style.allCases) { style in
                            SChoiceCard(title: style.title, subtitle: subtitle(style), selected: lock.style == style,
                                        height: 92, action: { lock.style = style }) {
                                LockStylePreview(style: style)
                            }
                        }
                    }
                }
                .disabled(!settings.showMedia)
                if lock.style != .off {
                    SRow("clock", L("Hiện khi", "Show")) {
                        SPicker($lock.mode, Array([LockScreenMusic.Mode.playing, .always]), title: { $0.title })
                    }
                }
            }
        }
    }

    private func subtitle(_ style: LockScreenMusic.Style) -> String {
        switch style {
        case .off: return L("Không hiện gì", "Nothing shown")
        case .compact: return L("Widget nhỏ dưới đồng hồ", "A small widget under the clock")
        case .full: return L("Ảnh bìa lớn và lời", "Big artwork and lyrics")
        }
    }
}

/// Màn hình khoá thu nhỏ: đồng hồ, kiểu trình phát đã chọn, ảnh đại diện.
private struct LockStylePreview: View {
    let style: LockScreenMusic.Style

    var body: some View {
        ZStack {
            SWallpaper()
            VStack(spacing: 5) {
                Text("9:41").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                switch style {
                case .off:
                    Spacer().frame(height: 22)
                case .compact:
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 14, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Capsule().fill(.white.opacity(0.9)).frame(width: 34, height: 3)
                            Capsule().fill(.white.opacity(0.5)).frame(width: 24, height: 3)
                        }
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35)))
                case .full:
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(.white.opacity(0.4)).frame(width: 44, height: 3)
                            Capsule().fill(.white).frame(width: 54, height: 4)
                            Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 3)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.22)))
                }
                Circle().fill(.white.opacity(0.7)).frame(width: 9, height: 9)
            }
        }
    }
}

// MARK: - Lịch

private struct CalendarPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SPage {
            SSection(L("Lịch", "Calendar"),
                     note: L("Muốn thấy cuộc họp sắp tới ngay cả khi notch thu gọn: Giao diện › Hai bên notch › Cuộc họp kế tiếp.",
                             "To see the next meeting on the closed notch: Appearance › Beside the closed notch › Next meeting.")) {
                SToggleRow(icon: "calendar", title: L("Lịch và cuộc họp", "Calendar and meetings"),
                           detail: L("Tuần hiện tại, sự kiện hôm nay và nút vào Meet, nằm cạnh trình phát nhạc.",
                                     "This week, today's events and a Meet button, next to the music player."),
                           divider: false, isOn: $settings.showCalendar)
                SRow("lock.shield", L("Quyền truy cập Lịch", "Calendar access"),
                     detail: L("Roost chỉ đọc lịch, không sửa hay gửi đi đâu.", "Roost only reads your calendars and never changes or sends them.")) {
                    Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane("Privacy_Calendars") }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Khay file

private struct TrayPane: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var alerts = AlertSettings.shared

    private static func expiryTitle(_ days: Int) -> String {
        switch days {
        case 0: return L("Không bao giờ", "Never")
        case 1: return L("Sau 1 ngày", "After 1 day")
        default: return L("Sau \(days) ngày", "After \(days) days")
        }
    }

    var body: some View {
        SPage {
            SSection(L("Khay file", "File tray"),
                     note: L("Khay chỉ giữ liên kết tới file gốc: di chuyển hay đổi tên thì file vẫn còn, xoá hoặc bỏ vào Thùng rác thì file tự rời khay.",
                             "The tray only keeps links to the original files: moving or renaming keeps them, deleting or trashing removes them.")) {
                SToggleRow(icon: "tray.full", title: L("Tab Khay", "Tray tab"),
                           detail: L("Kéo file lên notch để cất tạm, kéo ra để thả vào bất cứ đâu.", "Drag files onto the notch to keep them, drag them out to drop anywhere."),
                           divider: false, isOn: $settings.showTray)
            }
            SSection(L("Tự thêm vào khay", "Added automatically"),
                     reset: { settings.screenshotsToTray = true; alerts.downloadsToTray = true; settings.trayExpiryDays = 0 }) {
                SToggleRow(icon: "camera.viewfinder", title: L("Ảnh chụp màn hình", "Screenshots"),
                           detail: L("Ảnh vừa chụp vào khay, kể cả khi chụp vào clipboard.", "New screenshots land in the tray, even ones copied to the clipboard."),
                           divider: false, isOn: $settings.screenshotsToTray)
                SToggleRow(icon: "arrow.down.circle", title: L("File tải về", "Downloads"),
                           detail: L("File trong Downloads vào khay khi đã tải xong.", "Files in Downloads join the tray once they finish."),
                           isOn: $alerts.downloadsToTray)
                SRow("clock.arrow.circlepath", L("Tự dọn khay", "Auto-clear the tray")) {
                    SPicker($settings.trayExpiryDays, Array(SettingsStore.trayExpiryOptions), title: { Self.expiryTitle($0) })
                }
            }
            .disabled(!settings.showTray)
        }
    }
}

// MARK: - Gương

private struct MirrorPane: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        SPage {
            SSection(L("Gương", "Mirror"),
                     note: L("Camera chỉ bật khi tab Gương đang mở và tắt ngay khi bạn rời tab. Ảnh chỉ được lưu khi bạn bấm nút chụp.",
                             "The camera only runs while the Mirror tab is open and stops as soon as you leave it. Photos are saved only when you press a capture button.")) {
                SToggleRow(icon: "camera", title: L("Tab Gương", "Mirror tab"),
                           detail: L("Soi trước khi họp, đèn viền khi phòng tối, bấm một lần là vào Meet.", "Check yourself before a call, edge light in a dark room, one click to join Meet."),
                           divider: false, isOn: $settings.showMirror)
                SRow("lock.shield", L("Quyền camera", "Camera access")) {
                    Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { openPrivacyPane("Privacy_Camera") }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Thông báo

struct AlertsPane: View {
    @ObservedObject var alerts = AlertSettings.shared
    @ObservedObject var perms = PermissionWatch.shared

    var body: some View {
        SPage {
            SSection(L("Thẻ thông báo", "Alert card"),
                     note: L("Notch thả xuống thành một thẻ có icon, tiêu đề và một dòng giải thích. Rê chuột vào thì thẻ đứng yên, bấm vào thì mở đúng chỗ cần.",
                             "The notch drops down into a card with an icon, a title and a line of detail. Hover keeps it open, clicking opens the right place.")) {
                SBlock(divider: false) {
                    AlertPreview().frame(height: 112).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            SSection(L("Báo trên notch", "Notch alerts"),
                     note: L("Mất mạng chỉ báo khi kéo dài hơn vài giây, Wi-Fi chập chờn thoáng qua sẽ không làm phiền bạn. Cắm sạc luôn được báo.",
                             "Connection loss only shows when it lasts more than a few seconds. Plugging in the charger is always shown."),
                     reset: { alerts.battery = true; alerts.capsLock = true; alerts.network = true; alerts.hud = true }) {
                SToggleRow(icon: "battery.25percent", title: L("Pin yếu và pin đầy", "Low and full battery"),
                           detail: L("Báo ở 20% và 10%, và khi sạc đầy.", "At 20% and 10%, and when charging finishes."),
                           divider: false, isOn: $alerts.battery)
                SToggleRow(icon: "capslock", title: L("Bật tắt Caps Lock", "Caps Lock on and off"),
                           detail: L("Hiện ON hoặc OFF mỗi lần bấm.", "Shows ON or OFF every time you press it."),
                           isOn: $alerts.capsLock)
                SToggleRow(icon: "wifi.slash", title: L("Mất kết nối Internet", "Internet connection lost"),
                           detail: L("Và báo lại khi có mạng trở lại.", "And again when you're back online."),
                           isOn: $alerts.network)
                SToggleRow(icon: "speaker.wave.2", title: L("Thay HUD âm lượng và độ sáng", "Replace the volume and brightness HUD"),
                           detail: perms.accessibilityTrusted
                               ? L("Âm lượng, độ sáng màn hình và đèn bàn phím hiện gọn ở hai bên notch.",
                                   "Volume, display brightness and keyboard backlight show neatly beside the notch.")
                               : L("Cần quyền Trợ năng để bắt phím. Bật lên để cấp quyền.",
                                   "Needs Accessibility access to catch the keys. Turn it on to grant access."),
                           isOn: Binding(get: { alerts.hud }, set: { on in
                               alerts.hud = on
                               if on, !FaceUnlockService.isAccessibilityTrusted { _ = FaceUnlockService.promptForAccessibility() }
                           }))
            }
        }
    }
}

/// Thẻ thông báo mẫu (pin yếu) dưới một notch, trên nền giả desktop.
private struct AlertPreview: View {
    var body: some View {
        ZStack(alignment: .top) {
            SWallpaper()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    (Text(L("Pin yếu ", "Low battery ")).foregroundStyle(.white)
                     + Text("10%").foregroundStyle(Color(red: 1, green: 0.3, blue: 0.3)))
                        .font(.system(size: 13, weight: .bold))
                    Text(L("Bật Chế độ nguồn điện thấp hoặc cắm sạc.", "Turn on Low Power Mode or plug in."))
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                Image(systemName: "battery.25percent").font(.system(size: 22)).foregroundStyle(Color(red: 1, green: 0.3, blue: 0.3))
            }
            .padding(.horizontal, 18)
            .frame(width: 300, height: 74)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18).fill(.black))
        }
    }
}

// MARK: - Giữ máy thức

private struct KeepAwakePane: View {
    @ObservedObject var alerts = AlertSettings.shared
    private var installed = State(initialValue: ClosedLidMode.installed)
    private var installError = State<String?>(initialValue: nil)

    var body: some View {
        SPage {
            SSection(L("Giữ máy thức", "Keep awake"),
                     note: L("Mở notch, bấm ly cà phê để chọn thời gian: 15 phút tới 8 giờ, tới khi tắt, tới giờ hết làm hoặc tới khi một app thoát. Notch báo trước 2 phút khi sắp hết giờ.",
                             "Open the notch and click the coffee cup: 15 minutes to 8 hours, until you turn it off, until the end of the workday or until an app quits. The notch warns you 2 minutes before time runs out."),
                     reset: { alerts.workEndMinutes = 18 * 60; alerts.awakeStopOnLowBattery = true; alerts.awakeStopOnLid = true }) {
                SRow("briefcase", L("Giờ hết làm", "End of workday"),
                     detail: L("Dùng cho lựa chọn \"Tới giờ hết làm\".", "Used by the \"Until the end of the workday\" option."), divider: false) {
                    SPicker($alerts.workEndMinutes, Array(stride(from: 15 * 60, through: 23 * 60, by: 30)),
                            title: { String(format: "%d:%02d", $0 / 60, $0 % 60) })
                }
                SToggleRow(icon: "battery.0percent", title: L("Tự tắt khi pin còn 10%", "Turn off at 10% battery"),
                           isOn: $alerts.awakeStopOnLowBattery)
                SToggleRow(icon: "laptopcomputer", title: L("Tự tắt khi gập máy không có màn rời", "Turn off when the lid closes without a display"),
                           isOn: $alerts.awakeStopOnLid)
                SToggleRow(icon: "display", title: L("Gập máy vẫn chạy trên màn rời", "Keep running on an external display with the lid closed"),
                           detail: installed.wrappedValue
                               ? L("Kể cả khi không cắm sạc. Chỉ có tác dụng lúc đang giữ máy thức.",
                                   "Even without the charger. Only while keep awake is on.")
                               : L("macOS bắt máy ngủ khi gập lúc chạy pin. Cần cài một lần (hỏi mật khẩu) để Roost được tắt chế độ ngủ trong lúc giữ thức.",
                                   "macOS sleeps when the lid closes on battery. A one-time setup (asks for your password) lets Roost turn sleep off while keeping awake."),
                           isOn: $alerts.awakeClosedLid)
                if alerts.awakeClosedLid && !installed.wrappedValue {
                    SRow("lock.shield", L("Cài quyền chặn ngủ khi gập máy", "Set up closed-lid mode"),
                         detail: installError.wrappedValue) {
                        Button(L("Cài đặt…", "Set up…")) {
                            installError.wrappedValue = ClosedLidMode.install()
                            installed.wrappedValue = ClosedLidMode.installed
                        }
                        .buttonStyle(SButtonStyle(.primary))
                    }
                }
            }
        }
    }
}

// MARK: - Thú cưng

private struct PetPane: View {
    @ObservedObject var settings: SettingsStore

    private var pets: [(Theme, String, String)] {
        [(.standard, "🦊", L("Cáo nhỏ", "Little fox")),
         (.pixel, "🦖", L("Khủng long pixel", "Pixel dino")),
         (.cassette, "📼", "Walkman"),
         (.vangogh, "🎨", L("Hoạ sĩ tí hon", "Tiny painter"))]
    }

    var body: some View {
        SPage {
            SSection(L("Thú cưng", "Pet"),
                     note: L("Thú cưng nhún theo nhạc, ngủ gật khi máy rảnh, nhìn theo con trỏ và đeo tai nghe khi bạn dùng tai nghe.",
                             "The pet dances to music, dozes when the Mac is idle, follows the pointer and wears headphones when you do.")) {
                SToggleRow(icon: "pawprint", title: L("Thú cưng trên notch", "Notch pet"),
                           detail: L("Mỗi giao diện có một thú cưng riêng.", "Each theme has its own pet."),
                           divider: false, isOn: $settings.showPet)
                SBlock {
                    HStack(spacing: 12) {
                        ForEach(pets, id: \.0) { theme, emoji, name in
                            VStack(spacing: 6) {
                                Text(emoji).font(.system(size: 30))
                                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(theme.title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(settings.theme == theme ? SUI.accent.opacity(0.12) : Color.primary.opacity(0.03)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(settings.theme == theme ? SUI.accent : .clear, lineWidth: 1.5))
                        }
                    }
                    .opacity(settings.showPet ? 1 : 0.5)
                }
            }
        }
    }
}

// MARK: - Giới thiệu

private struct AboutPane: View {
    @ObservedObject var updater = AppUpdater.shared

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return L("Chưa kiểm tra lần nào.", "Not checked yet.") }
        let f = RelativeDateTimeFormatter()
        f.locale = Lang.locale
        return L("Lần kiểm tra gần nhất: \(f.localizedString(for: date, relativeTo: Date())).", "Last checked \(f.localizedString(for: date, relativeTo: Date())).")
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        SPage {
            SSection(nil) {
                SBlock(divider: false, padding: 18) {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Roost").font(.system(size: 22, weight: .semibold))
                            Text(L("Phiên bản \(version)", "Version \(version)")).foregroundStyle(.secondary)
                            Text(L("Tai thỏ MacBook, làm được nhiều hơn.", "Your MacBook notch, doing more."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SSection(L("Cập nhật", "Updates"),
                     note: L("Roost tìm bản mới mỗi ngày một lần qua GitHub Releases. Mỗi bản được ký bằng khoá riêng của Roost; chữ ký không khớp thì Roost không cài.",
                             "Roost looks for a new version once a day on GitHub Releases. Every update is signed with Roost's own key; if the signature doesn't match, it isn't installed.")) {
                SToggleRow(icon: "arrow.triangle.2.circlepath", title: L("Tự kiểm tra bản mới", "Check for updates automatically"),
                           isOn: $updater.autoCheck)
                SRow("arrow.down.circle", L("Kiểm tra ngay", "Check now"), detail: lastCheckText, divider: false) {
                    Button(L("Kiểm tra", "Check")) { updater.checkNow() }
                        .controlSize(.small)
                        .disabled(!updater.canCheck)
                }
            }
            SSection(L("Tài nguyên", "Resources")) {
                SRow("sparkles.rectangle.stack", L("Hướng dẫn cài đặt", "Setup guide"),
                     detail: L("Cấp quyền và nối với Claude Code.", "Permissions and the Claude Code hook."), divider: false) {
                    Button(L("Mở", "Open")) { OnboardingWindowController.shared.show() }.controlSize(.small)
                }
                SRow("chevron.left.forwardslash.chevron.right", L("Mã nguồn", "Source code")) {
                    Link(L("GitHub", "GitHub"), destination: URL(string: "https://github.com/letoan1/notch-app")!)
                }
            }
            SSection(L("Giấy phép", "License"),
                     note: L("Model nhận diện khuôn mặt ArcFace không thuộc giấy phép MIT và chỉ được dùng phi thương mại. Font VT323 theo SIL OFL, mediaremote-adapter theo BSD 3-Clause.",
                             "The ArcFace face model is not covered by the MIT license and is for non-commercial use only. The VT323 font is under the SIL OFL and mediaremote-adapter under BSD 3-Clause.")) {
                SRow("doc.text", L("Roost", "Roost"), divider: false) {
                    Text("MIT").foregroundStyle(.secondary)
                }
            }
        }
    }
}
