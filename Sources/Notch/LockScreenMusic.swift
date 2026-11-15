import AppKit
import Combine
import FaceUnlockKit
import SwiftUI

// MARK: - Nhạc trên màn hình khoá

/// Widget nhạc trên màn hình khoá: ảnh bìa, tên bài, tiến độ, nút ⏮ ⏯ ⏭.
/// Đưa lên màn hình khoá bằng SkyLight (cùng cách với mở khoá bằng khuôn mặt), chỉ tồn tại khi máy đang khoá.
@MainActor
final class LockScreenMusic: ObservableObject {
    static let shared = LockScreenMusic()

    enum Mode: String, CaseIterable, Identifiable {
        case playing, always, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .playing: return L("Chỉ khi đang phát nhạc", "Only while music plays")
            case .always: return L("Hiện mọi lúc", "Always")
            case .off: return L("Tắt", "Off")
            }
        }
    }

    /// Kiểu hiển thị: tắt, widget gọn, hoặc trình phát đầy đủ kèm lời.
    enum Style: String, CaseIterable, Identifiable {
        case off, compact, full
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return L("Tắt", "Off")
            case .compact: return L("Gọn", "Compact")
            case .full: return L("Trình phát đầy đủ", "Full player")
            }
        }
    }

    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "lockMusic.mode"); refresh() } }
    @Published var style: Style { didSet { UserDefaults.standard.set(style.rawValue, forKey: "lockMusic.style"); refresh() } }

    private var media: NowPlaying?
    private var window: LockMusicWindow?
    private var locked = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private var asleep = false

    private init() {
        let d = UserDefaults.standard
        let savedMode = Mode(rawValue: d.string(forKey: "lockMusic.mode") ?? "") ?? .playing
        // Bản cũ gộp "Tắt" vào chế độ: chuyển sang kiểu hiển thị.
        style = Style(rawValue: d.string(forKey: "lockMusic.style") ?? "") ?? (savedMode == .off ? .off : .compact)
        mode = savedMode == .off ? .playing : savedMode
    }

    func start(media: NowPlaying) {
        guard self.media == nil else { return }
        self.media = media
        let center = DistributedNotificationCenter.default()
        // Thông báo khoá / mở khoá giả mạo được → chỉ là tín hiệu, luôn xác nhận lại bằng CGSession.
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                MainActor.assumeIsolated { self?.syncLock() }
            }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLock() }
        })
        // Màn hình tắt (ngủ) thì cất hẳn để dừng animation; sáng lại thì hiện lại nếu vẫn đang khoá.
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = true; self?.refresh() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = false; self?.syncLock() }
        })
        // Đang khoá mà nhạc bắt đầu / dừng: hiện hoặc cất theo chế độ.
        media.$track.removeDuplicates { $0?.isPlaying == $1?.isPlaying && $0?.bundleID == $1?.bundleID }
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
            .store(in: &cancellables)
        syncLock()
    }

    private func syncLock() {
        locked = FaceUnlockService.isScreenActuallyLocked
        refresh()
    }

    private var shouldShow: Bool {
        guard locked, !asleep, style != .off, let media else { return false }
        // Chỉ nhạc từ Spotify / Apple Music; YouTube, trình duyệt, video… không hiện trình phát màn hình khoá.
        if let track = media.track, !LyricsStore.supportedApps.contains(track.bundleID) { return false }
        switch mode {
        case .off: return false
        case .always: return true
        // Đã hiện rồi thì giữ tới khi mở khoá, để tạm dừng xong vẫn bấm phát lại được.
        case .playing: return media.isPlaying || (window?.isVisible == true && media.hasTrack)
        }
    }

    private func refresh() {
        if shouldShow { show() } else { hide() }
    }

    private func show() {
        guard let media else { return }
        let full = style == .full
        // Đổi kiểu hiển thị thì dựng lại cửa sổ (nội dung và cỡ khác nhau).
        if let old = window, old.full != full { hide(); window = nil }
        let w = window ?? LockMusicWindow(media: media, full: full)
        window = w
        guard !w.isVisible else { return }
        w.place()
        w.orderFrontRegardless()
        // Chỉ chuyển lên được khi máy thật sự đang khoá; không được thì cất (không để lại trên desktop).
        if !FaceUnlockService.moveToLockScreen(w) { w.orderOut(nil) }
    }

    private func hide() {
        guard let window else { return }
        if window.isVisible {
            FaceUnlockService.restoreFromLockScreen(window)
            window.orderOut(nil)
        }
        // Huỷ hẳn: cửa sổ ẩn mà còn giữ view thì vẫn theo dõi nhạc, lời, đồng hồ → SwiftUI layout liên tục.
        window.contentView = nil
        self.window = nil
    }
}

/// Cửa sổ không lấy focus (không chen vào ô mật khẩu), đặt dưới đồng hồ màn hình khoá.
final class LockMusicWindow: NSPanel {
    static let size = CGSize(width: 360, height: 104)
    let full: Bool

    @MainActor
    init(media: NowPlaying, full: Bool = false) {
        self.full = full
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = full ? NSHostingView(rootView: AnyView(LockFullPlayerView(media: media)))
                           : NSHostingView(rootView: AnyView(LockMusicView(media: media)))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Giữa màn hình theo chiều ngang, ngay dưới đồng hồ (khoảng 1/3 từ trên xuống); ô mật khẩu ở dưới đáy.
    @MainActor
    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let f = screen.frame
        if full {
            setFrame(Self.fullFrame(in: f), display: true)
            return
        }
        let top = f.maxY - f.height * 0.34
        setFrame(NSRect(x: f.midX - Self.size.width / 2, y: top - Self.size.height,
                        width: Self.size.width, height: Self.size.height), display: true)
    }

    /// Dải giữa đồng hồ (kết thúc ~32% từ trên) và ảnh đại diện (bắt đầu ~80%): rộng ~55% màn hình.
    static func fullFrame(in f: NSRect) -> NSRect {
        let width = min(max(f.width * 0.55, 640), 1000)
        let top = f.maxY - f.height * 0.34
        let height = min(max(f.height * 0.40, 300), 440)
        return NSRect(x: f.midX - width / 2, y: top - height, width: width, height: height)
    }
}

/// Màu nhấn theo giao diện (nhẹ thôi: màn hình khoá đã có hình nền riêng).
private enum LockTint {
    @MainActor static func accent(_ media: NowPlaying) -> Color {
        if Theme.isVanGogh { return VG.yellow }
        if Theme.isPixel { return PixelPalette.pink }
        if Theme.isCassette { return Color(red: 0.98, green: 0.55, blue: 0.35) }
        return media.accent
    }
}

struct LockMusicView: View {
    @ObservedObject var media: NowPlaying

    var body: some View {
        let accent = LockTint.accent(media)
        HStack(spacing: 14) {
            Artwork(image: media.artwork, corner: Theme.isPixel ? 2 : 12)
                .frame(width: 72, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if let track = media.track { LockSourceIcon(bundleID: track.bundleID, size: 22).offset(x: 6, y: 6) }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(media.track?.title ?? L("Chưa phát gì", "Nothing playing"))
                    .font(.ui(14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(media.track?.artist ?? "")
                    .font(.ui(12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                if let track = media.track, track.duration > 0 {
                    LockProgress(track: track, accent: accent)
                } else if media.track != nil {
                    LiveBadge()
                }
                HStack(spacing: media.modes == nil ? 18 : 10) {
                    if let modes = media.modes {
                        ModeButton(kind: .shuffle, modes: modes, plain: true, side: 22, action: media.toggleShuffle)
                    }
                    button("backward.fill", 13) { media.previous() }
                    button(media.isPlaying ? "pause.fill" : "play.fill", 17) { media.playPause() }
                    button("forward.fill", 13) { media.next() }
                    if let modes = media.modes {
                        ModeButton(kind: .repeatMode, modes: modes, plain: true, side: 22, action: media.cycleRepeat)
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: LockMusicWindow.size.width, height: LockMusicWindow.size.height)
        .background(
            RoundedRectangle(cornerRadius: Theme.isPixel ? 4 : 22, style: .continuous)
                .fill(.black.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: Theme.isPixel ? 4 : 22, style: .continuous)
                    .stroke(Theme.isVanGogh ? VG.yellow.opacity(0.6) : .white.opacity(0.14), lineWidth: Theme.isPixel ? 2 : 1))
        )
        .environment(\.colorScheme, .dark)
    }

    private func button(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Thanh tiến độ đơn giản, cập nhật mỗi giây (chỉ chạy khi màn hình đang khoá).
private struct LockProgress: View {
    let track: Track
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let ratio = min(max(track.position(at: ctx.date) / track.duration, 0), 1)
            HStack(spacing: 7) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(accent).frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 4)
                Text(ProgressRow.format(track.position(at: ctx.date)))
                    .font(.ui(10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// Cài đặt › Tab: kiểu hiển thị nhạc trên màn hình khoá và khi nào hiện.
struct LockMusicPicker: View {
    @ObservedObject var lock = LockScreenMusic.shared
    @ObservedObject var settings = SettingsStore.shared   // dựng lại khi đổi ngôn ngữ

    var body: some View {
        Picker(L("Trên màn hình khoá", "On the lock screen"), selection: $lock.style) {
            ForEach(LockScreenMusic.Style.allCases) { Text($0.title).tag($0) }
        }
        if lock.style != .off {
            Picker(L("Hiện khi", "Show"), selection: $lock.mode) {
                ForEach([LockScreenMusic.Mode.playing, .always]) { Text($0.title).tag($0) }
            }
        }
    }
}

// MARK: - Trình phát đầy đủ

/// Bảng lớn giữa đồng hồ và ô mật khẩu: nền màu ảnh bìa chuyển động, ảnh bìa, điều khiển, lời chạy theo nhạc.
/// Lời chỉ cho Spotify và Apple Music (cùng quy tắc với notch).
struct LockFullPlayerView: View {
    @ObservedObject var media: NowPlaying
    @ObservedObject var store = LyricsStore.shared

    private var showLyrics: Bool {
        guard let track = media.track, LyricsStore.supports(track) else { return false }
        return store.enabled || track.bundleID == "com.apple.Music"
    }

    var body: some View {
        GeometryReader { geo in
            let corner: CGFloat = Theme.isPixel ? 6 : 30
            let art = min(geo.size.height - (showLyrics ? 190 : 80), showLyrics ? 210 : 250)
            ZStack {
                // Liquid Glass (macOS 26+): kính trong nhìn xuyên hình nền màn hình khoá, ngả nhẹ màu ảnh bìa.
                // Máy cũ hơn: nền màu ảnh bìa trôi chậm như trước.
                if #available(macOS 26.0, *), !Theme.isPixel {
                    Color.clear
                        .glassEffect(.regular.tint(LockTint.accent(media).opacity(0.18)),
                                     in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                } else {
                    DriftingArtwork(image: media.artwork)
                    Color.black.opacity(0.38)
                }
                if showLyrics {
                    HStack(alignment: .center, spacing: 36) {
                        info(art: art, stacked: true)
                        LyricsLinesView(store: store, size: min(max(geo.size.width / 34, 20), 30), spacing: 14, fullscreen: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 34)
                    .padding(.vertical, 22)
                } else {
                    info(art: art, stacked: false)
                        .padding(.horizontal, 40)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Theme.isVanGogh ? VG.yellow.opacity(0.6) : .white.opacity(0.16), lineWidth: Theme.isPixel ? 2 : 1))
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, SettingsStore.shared.locale)
        .onAppear { store.bind(media); store.attach() }
        .onDisappear { store.detach() }
    }

    /// stacked: ảnh bìa trên, chữ và nút dưới (có cột lời). Không có lời: ảnh bìa trái, chữ và nút phải.
    @ViewBuilder
    private func info(art: CGFloat, stacked: Bool) -> some View {
        let accent = LockTint.accent(media)
        let artwork = Artwork(image: media.artwork, corner: Theme.isPixel ? 3 : 16)
            .frame(width: art, height: art)
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
            .overlay(alignment: .bottomTrailing) {
                if let track = media.track { LockSourceIcon(bundleID: track.bundleID, size: 34).offset(x: 8, y: 8) }
            }
        let details = VStack(alignment: .leading, spacing: stacked ? 8 : 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(media.track?.title ?? L("Chưa phát gì", "Nothing playing"))
                    .font(.ui(stacked ? 17 : 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(media.track?.artist ?? "")
                    .font(.ui(stacked ? 13 : 17))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1)
            if let track = media.track, track.duration > 0 {
                LockProgress(track: track, accent: accent)
            } else if media.track != nil {
                LiveBadge()
            }
            HStack(spacing: media.modes == nil ? (stacked ? 26 : 34) : (stacked ? 8 : 18)) {
                if let modes = media.modes {
                    ModeButton(kind: .shuffle, modes: modes, plain: true, side: stacked ? 24 : 30, action: media.toggleShuffle)
                }
                control("backward.fill", stacked ? 17 : 22) { media.previous() }
                control(media.isPlaying ? "pause.fill" : "play.fill", stacked ? 24 : 30) { media.playPause() }
                control("forward.fill", stacked ? 17 : 22) { media.next() }
                if let modes = media.modes {
                    ModeButton(kind: .repeatMode, modes: modes, plain: true, side: stacked ? 24 : 30, action: media.cycleRepeat)
                }
            }
            .frame(maxWidth: .infinity, alignment: stacked ? .center : .leading)
        }
        if stacked {
            VStack(alignment: .leading, spacing: 14) { artwork; details }
                .frame(width: art)
        } else {
            HStack(spacing: 32) {
                artwork
                details.frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 1.9, height: size * 1.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Icon app đang phát trên màn hình khoá: không bấm được (bấm sẽ mở app sau ô mật khẩu), chỉ để nhận ra nguồn.
private struct LockSourceIcon: View {
    let bundleID: String
    let size: CGFloat
    var body: some View {
        if SourceAppIcon.enabled, let icon = SourceAppIcon.icon(for: bundleID) {
            Image(nsImage: icon).resizable()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
    }
}
