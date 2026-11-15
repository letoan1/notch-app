import SwiftUI
import AppKit

// Bố cục notch mở: mỗi thao tác đặt ở cột nút tròn bên trái, cột bên phải, thanh công cụ (góc phải hàng tab),
// hoặc không dùng (ẩn hẳn). Nút Cài đặt luôn có ở cuối thanh công cụ. Mỗi cột tối đa 3 nút.

enum NotchAction: String, CaseIterable, Codable, Identifiable {
    case keepAwake, usage, lyrics, headphones, cleanKeyboard, quit
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepAwake: return L("Giữ máy thức", "Keep awake")
        case .usage: return L("Mức dùng Claude", "Claude usage")
        case .lyrics: return L("Lời bài hát", "Lyrics")
        case .headphones: return L("Pin tai nghe", "Headphone battery")
        case .cleanKeyboard: return L("Lau phím", "Clean keyboard")
        case .quit: return L("Thoát", "Quit")
        }
    }

    var symbol: String {
        switch self {
        case .keepAwake: return "cup.and.saucer"
        case .usage: return "gauge.with.dots.needle.33percent"
        case .lyrics: return "quote.bubble"
        case .headphones: return "headphones"
        case .cleanKeyboard: return "keyboard"
        case .quit: return "power"
        }
    }

    /// Có tác dụng lúc này không (không thì ẩn khỏi notch, vẫn kéo thả được trong Cài đặt).
    @MainActor func available(media: NowPlaying, settings: SettingsStore) -> Bool {
        switch self {
        case .lyrics: return LyricsStore.shared.enabled && LyricsStore.supports(media.track)
        case .headphones: return BluetoothAudio.shared.name != nil
        default: return true
        }
    }

    @MainActor func perform(model: NotchModel?) {
        switch self {
        case .keepAwake: KeepAwakeMenu.shared.pop()
        case .usage:
            if ClaudeUsageAPI.shared.enabled || ClaudeUsage.shared.hasData {
                withAnimation(.easeOut(duration: 0.18)) { ClaudeUsageAPI.shared.panelOpen.toggle() }
            } else {
                SettingsWindowController.shared.show(pane: "usage")
            }
        case .lyrics:
            model?.tab = .media
            LyricsStore.shared.showInNotch.toggle()
        case .headphones: BluetoothAudio.shared.refresh()
        case .cleanKeyboard: KeyboardCleaner.shared.toggle()
        case .quit: NSApp.terminate(nil)
        }
    }
}

enum LayoutSlot: String { case left, right, toolbar, unused }

struct NotchLayout: Codable, Equatable {
    static let maxOrbs = 3

    var left: [NotchAction] = []
    var right: [NotchAction] = []
    var toolbar: [NotchAction] = [.usage, .keepAwake]

    static let standard = NotchLayout()

    init() {}

    // Đọc lỏng: bỏ qua mục không còn tồn tại (vd. "settings" cũ), cắt cột quá 3 nút.
    private enum CodingKeys: String, CodingKey { case left, right, toolbar }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ k: CodingKeys) -> [NotchAction] {
            ((try? c.decode([String].self, forKey: k)) ?? []).compactMap(NotchAction.init(rawValue:))
        }
        left = Array(list(.left).prefix(Self.maxOrbs))
        right = Array(list(.right).prefix(Self.maxOrbs))
        toolbar = list(.toolbar)
    }

    func items(_ slot: LayoutSlot) -> [NotchAction] {
        switch slot {
        case .left: return left
        case .right: return right
        case .toolbar: return toolbar
        case .unused: return NotchAction.allCases.filter { !(left + right + toolbar).contains($0) }
        }
    }

    func slot(of action: NotchAction) -> LayoutSlot {
        if left.contains(action) { return .left }
        if right.contains(action) { return .right }
        if toolbar.contains(action) { return .toolbar }
        return .unused
    }
}

@MainActor
final class NotchLayoutStore: ObservableObject {
    static let shared = NotchLayoutStore()
    static let key = "notch.layout.v1"

    @Published var layout: NotchLayout {
        didSet {
            // Bố cục mặc định thì không lưu khoá nào.
            if layout == .standard {
                UserDefaults.standard.removeObject(forKey: Self.key)
            } else if let data = try? JSONEncoder().encode(layout) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(NotchLayout.self, from: data) {
            layout = saved
        } else {
            layout = .standard
        }
    }

    /// Chuyển một mục sang chỗ khác, đứng trước `before` nếu có (thả lên một mục khác).
    /// Cột tròn đã đủ 3: thả lên một nút thì hai nút đổi chỗ, thả vào chỗ trống thì từ chối.
    @discardableResult
    func move(_ action: NotchAction, to slot: LayoutSlot, before: NotchAction? = nil) -> Bool {
        var l = layout
        let from = l.slot(of: action)
        let fromIndex = l.items(from).firstIndex(of: action) ?? 0
        l.left.removeAll { $0 == action }
        l.right.removeAll { $0 == action }
        l.toolbar.removeAll { $0 == action }
        func list(_ s: LayoutSlot) -> WritableKeyPath<NotchLayout, [NotchAction]>? {
            switch s {
            case .left: return \.left
            case .right: return \.right
            case .toolbar: return \.toolbar
            case .unused: return nil
            }
        }
        if let kp = list(slot) {
            if slot != .toolbar, l[keyPath: kp].count >= NotchLayout.maxOrbs {
                guard let before, let i = l[keyPath: kp].firstIndex(of: before) else { return false }
                l[keyPath: kp][i] = action
                if let back = list(from) {
                    l[keyPath: back].insert(before, at: min(fromIndex, l[keyPath: back].count))
                }
            } else if let before, let i = l[keyPath: kp].firstIndex(of: before) {
                l[keyPath: kp].insert(action, at: i)
            } else {
                l[keyPath: kp].append(action)
            }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layout = l }
        return true
    }

    func reset() { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { layout = .standard } }

    /// Bề ngang mỗi cột nút tròn (nút + khe), 0 khi cột trống. Dùng cho vùng giữ notch mở.
    static let orbSize: CGFloat = 30
    static let orbGap: CGFloat = 10
    func orbInset(_ slot: LayoutSlot) -> CGFloat {
        layout.items(slot).isEmpty ? 0 : Self.orbSize + Self.orbGap
    }
}

// MARK: - Nút tròn trên notch thật

/// Hai cột nút tròn nằm ngoài khung notch mở, canh mép trên.
struct NotchOrbColumns: View {
    @ObservedObject var store = NotchLayoutStore.shared
    @ObservedObject var media: NowPlaying
    @ObservedObject var settings: SettingsStore
    @ObservedObject var lyrics = LyricsStore.shared
    @ObservedObject var bt = BluetoothAudio.shared
    let model: NotchModel
    let panelWidth: CGFloat

    var body: some View {
        let slotWidth = NotchLayoutStore.orbSize + NotchLayoutStore.orbGap
        HStack(alignment: .top, spacing: 0) {
            column(.left).frame(width: slotWidth, alignment: .leading)
            Color.clear.frame(width: panelWidth, height: 1)
            column(.right).frame(width: slotWidth, alignment: .trailing)
        }
        .fixedSize()
    }

    private func column(_ slot: LayoutSlot) -> some View {
        VStack(spacing: 8) {
            ForEach(store.layout.items(slot).filter { $0.available(media: media, settings: settings) }) { action in
                NotchOrb(action: action) { action.perform(model: model) }
            }
        }
        .padding(.top, 4)
    }
}

/// Một nút tròn theo giao diện: đen (Mặc định), ô vuông viền pixel, phím kem (Cassette), xanh đêm viền vàng (Van Gogh).
struct NotchOrb: View {
    let action: NotchAction
    let tap: () -> Void
    @ObservedObject var awake = KeepAwake.shared
    @ObservedObject var usage = ClaudeUsage.shared
    @ObservedObject var extras = ClaudeExtras.shared
    @ObservedObject var cleaner = KeyboardCleaner.shared
    private var hover = State(initialValue: false)

    init(action: NotchAction, tap: @escaping () -> Void) {
        self.action = action
        self.tap = tap
    }

    var body: some View {
        let p = HeaderPalette.current
        let size = NotchLayoutStore.orbSize
        let shape = RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : size / 2, style: .continuous)
        Button(action: tap) {
            content(p)
                .frame(width: size, height: size)
                // Nền đặc (nút nằm trên hình nền desktop), rồi lớp màu của giao diện.
                .background(shape.fill(p.fill))
                .background(shape.fill(Theme.isCassette ? CassettePalette.label : Color.black))
                .overlay(shape.stroke(hover.wrappedValue ? p.text.opacity(0.5) : p.border, lineWidth: Theme.isPixel ? 2 : 1))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .scaleEffect(hover.wrappedValue ? 1.08 : 1)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover.wrappedValue)
        .help(action.title)
    }

    @ViewBuilder private func content(_ p: HeaderPalette) -> some View {
        switch action {
        case .usage:
            if let l = usage.limit(.fiveHour) {
                let pct = Int((ClaudeUsage.fraction(l, show: extras.usageShow) * 100).rounded())
                ZStack {
                    UsageGauge(limit: l, style: .ring, show: extras.usageShow, size: 22, lineWidth: 2.5, track: p.track)
                    Text("\(pct)").font(.ui(8.5, weight: .bold).monospacedDigit()).foregroundStyle(p.text)
                }
            } else {
                icon(p)
            }
        case .headphones:
            HeadphoneBatteryGlyph(size: 22, track: p.track, ink: p.text)
        case .cleanKeyboard:
            ThemedIcon(symbol: cleaner.locked ? "lock.fill" : "keyboard")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(cleaner.locked ? AlertCard.color(.blue) : p.text)
        case .keepAwake:
            ThemedIcon(symbol: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(awake.active ? KeepAwakeButton.activeColor : p.text)
        default:
            icon(p)
        }
    }

    private func icon(_ p: HeaderPalette) -> some View {
        ThemedIcon(symbol: action.symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(p.text)
    }
}

/// Nút nhỏ trên thanh công cụ (góc phải hàng tab) cho các thao tác không nằm trong viên trạng thái.
struct HeaderToolbarButton: View {
    let action: NotchAction
    let model: NotchModel
    @ObservedObject var audio = BluetoothAudio.shared
    @ObservedObject var cleaner = KeyboardCleaner.shared

    private var symbol: String {
        switch action {
        case .headphones: return audio.symbol ?? action.symbol
        case .cleanKeyboard: return cleaner.locked ? "lock.fill" : action.symbol
        default: return action.symbol
        }
    }

    var body: some View {
        Button { action.perform(model: model) } label: {
            HStack(spacing: 3) {
                ThemedIcon(symbol: symbol)
                    .font(.ui(12, weight: .semibold))
                if action == .headphones, let level = audio.level {
                    Text("\(level)%").font(.ui(11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(KeepAwakeButton.idleColor)
            .frame(minWidth: 24, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.title)
    }
}

// MARK: - Trình sửa bố cục trong Cài đặt

/// Xem trước notch mở trên nền desktop: hai cột nút tròn, thanh công cụ, và khay "Chưa dùng" bên dưới.
/// Kéo icon để đổi chỗ, kéo vào khay để bỏ.
struct NotchLayoutEditor: View {
    @ObservedObject var store = NotchLayoutStore.shared
    private var dragging = State<NotchAction?>(initialValue: nil)
    private var target = State<LayoutSlot?>(initialValue: nil)

    var body: some View {
        VStack(spacing: 10) {
            preview
                .frame(height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(L("Mỗi bên tối đa 3 nút tròn, thả lên nút có sẵn để đổi chỗ. Cột trống thì ẩn.",
                   "Up to 3 orbs per side; drop onto an orb to swap. An empty column is hidden."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            tray
        }
    }

    // Notch mở thu nhỏ, cột tròn hai bên.
    private var preview: some View {
        ZStack(alignment: .top) {
            SWallpaper()
            HStack(alignment: .top, spacing: 12) {
                orbColumn(.left)
                panel
                orbColumn(.right)
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(.white.opacity(i == 0 ? 0.9 : 0.35)).frame(width: 7, height: 7)
                }
                Spacer(minLength: 8)
                // Thanh công cụ: các mục đặt ở đây + nút Cài đặt cố định.
                HStack(spacing: 4) {
                    ForEach(store.layout.toolbar) { action in
                        chip(action, dark: true, small: true)
                            .onDrop(of: [.text], isTargeted: nil) { _ in drop(.toolbar, before: action) }
                    }
                    Image(systemName: "gearshape").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 22)
                }
                .padding(.horizontal, 5)
                .frame(minWidth: 44, minHeight: 28)
                .background(Capsule().fill(.white.opacity(target.wrappedValue == .toolbar ? 0.22 : 0.1)))
                .overlay(Capsule().strokeBorder(target.wrappedValue == .toolbar ? SUI.accent : .clear, lineWidth: 1.5))
                .onDrop(of: [.text], isTargeted: targetBinding(.toolbar)) { _ in drop(.toolbar) }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            Spacer()
            Text(L("Kéo icon để đổi chỗ. Kéo vào khay để bỏ.", "Drag an icon to move it. Drag it into the tray to remove it."))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 12)
        }
        .frame(width: 300, height: 128)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous).fill(.black))
    }

    private func orbColumn(_ slot: LayoutSlot) -> some View {
        let items = store.layout.items(slot)
        let on = target.wrappedValue == slot
        // Luôn 3 ô: nút đã đặt rồi tới ô trống viền đứt.
        return VStack(spacing: 7) {
            ForEach(items) { action in
                chip(action, dark: true, small: false)
                    .onDrop(of: [.text], isTargeted: nil) { _ in drop(slot, before: action) }
            }
            ForEach(0..<max(NotchLayout.maxOrbs - items.count, 0), id: \.self) { _ in
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(.white.opacity(on ? 0.95 : 0.45))
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.top, 6)
        .frame(width: 44)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: targetBinding(slot)) { _ in drop(slot) }
    }

    // Khay "Chưa dùng".
    private var tray: some View {
        let unused = store.layout.items(.unused)
        let on = target.wrappedValue == .unused
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Chưa dùng", "Not in use")).font(.system(size: 12.5, weight: .semibold))
                Text(L("Kéo vào notch để thêm.", "Drag onto the notch to add."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button { store.reset() } label: {
                    Label(L("Đặt lại mặc định", "Reset to default"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SButtonStyle(.link))
                .disabled(store.layout == .standard)
            }
            HStack(spacing: 8) {
                ForEach(unused) { action in
                    chip(action, dark: false, small: false, labeled: true)
                }
                if unused.isEmpty {
                    Text(L("Mọi mục đều đang ở trên notch.", "Everything is on the notch."))
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .frame(height: 28)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(on ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(on ? SUI.accent : Color.primary.opacity(0.06), style: StrokeStyle(lineWidth: on ? 1.5 : 1, dash: on ? [5, 4] : [])))
        .onDrop(of: [.text], isTargeted: targetBinding(.unused)) { _ in drop(.unused) }
    }

    /// Một mục kéo được: nút tròn đen (trên notch) hoặc chip có chữ (trong khay).
    @ViewBuilder
    private func chip(_ action: NotchAction, dark: Bool, small: Bool, labeled: Bool = false) -> some View {
        let isDragging = dragging.wrappedValue == action
        Group {
            if labeled {
                HStack(spacing: 6) {
                    Image(systemName: action.symbol).font(.system(size: 11.5, weight: .medium))
                    Text(action.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            } else {
                Image(systemName: action.symbol)
                    .font(.system(size: small ? 10.5 : 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: small ? 22 : 30, height: small ? 22 : 30)
                    .background(Circle().fill(small ? Color.white.opacity(0.12) : Color.black))
                    .overlay(Circle().strokeBorder(.white.opacity(small ? 0 : 0.25)))
                    .shadow(color: .black.opacity(small ? 0 : 0.3), radius: 3, y: 1)
            }
        }
        .opacity(isDragging ? 0.35 : 1)
        .help(action.title)
        .onDrag {
            dragging.wrappedValue = action
            return NSItemProvider(object: action.rawValue as NSString)
        }
    }

    private func targetBinding(_ slot: LayoutSlot) -> Binding<Bool> {
        Binding(get: { target.wrappedValue == slot },
                set: { on in
                    if on { target.wrappedValue = slot } else if target.wrappedValue == slot { target.wrappedValue = nil }
                })
    }

    private func drop(_ slot: LayoutSlot, before: NotchAction? = nil) -> Bool {
        defer { dragging.wrappedValue = nil; target.wrappedValue = nil }
        guard let action = dragging.wrappedValue, action != before else { return false }
        return store.move(action, to: slot, before: before)
    }
}
