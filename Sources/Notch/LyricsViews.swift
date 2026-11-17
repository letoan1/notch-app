import AppKit
import SwiftUI

/// Màu chữ lời theo giao diện.
enum LyricsStyle {
    static var active: Color {
        if Theme.isPixel { return PixelPalette.pink }
        if Theme.isCassette { return CassettePalette.label }
        if Theme.isVanGogh { return VG.yellow }
        return .white
    }
    static var dim: Color {
        if Theme.isPixel { return PixelPalette.dim }
        if Theme.isCassette { return CassettePalette.line.opacity(0.7) }
        if Theme.isVanGogh { return VG.muted.opacity(0.75) }
        return .white.opacity(0.38)
    }
    static var ink: Color {
        if Theme.isPixel { return PixelPalette.border }
        if Theme.isCassette { return CassettePalette.label }
        if Theme.isVanGogh { return VG.cream }
        return .white
    }
}

/// Nút bật/tắt lời trên trình phát (góc của khu nhạc).
struct LyricsToggleButton: View {
    @ObservedObject var store = LyricsStore.shared
    private var hover = State(initialValue: false)

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.25)) { store.showInNotch.toggle() } } label: {
            Image(systemName: store.showInNotch ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.showInNotch ? background : LyricsStyle.ink.opacity(hover.wrappedValue ? 1 : 0.7))
                .frame(width: 24, height: 22)
                .background {
                    if Theme.isPixel {
                        Rectangle().fill(store.showInNotch ? PixelPalette.pink : .clear)
                            .overlay(Rectangle().strokeBorder(PixelPalette.dim, lineWidth: 2))
                    } else if Theme.isCassette {
                        RoundedRectangle(cornerRadius: 4).fill(store.showInNotch ? CassettePalette.band : CassettePalette.shell)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(CassettePalette.shellEdge))
                    } else {
                        Capsule().fill(store.showInNotch ? LyricsStyle.active : .white.opacity(hover.wrappedValue ? 0.14 : 0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help(L("Lời bài hát", "Lyrics"))
    }

    private var background: Color {
        if Theme.isPixel || Theme.isVanGogh { return .black }
        if Theme.isCassette { return CassettePalette.ink }
        return .black
    }
}

/// Lời bài hát thay cho trình phát trong notch.
struct NotchLyricsView: View {
    @ObservedObject var media: NowPlaying
    @ObservedObject var store = LyricsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            LyricsLinesView(store: store, size: 15, spacing: 7, compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity)
        .onAppear { store.bind(media); store.attach() }
        .onDisappear { store.detach() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Artwork(image: media.artwork, corner: 6)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(media.track?.title ?? "")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(LyricsStyle.ink)
                Text(media.track?.artist ?? "")
                    .font(.ui(10.5))
                    .foregroundStyle(LyricsStyle.dim)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            Button { LyricsFullscreen.shared.show(media: media) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LyricsStyle.ink.opacity(0.75))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Xem lời toàn màn hình", "Full-screen lyrics"))
            LyricsToggleButton()
        }
    }
}

/// Danh sách dòng lời: dòng đang hát sáng và lớn, cuộn mượt khi sang dòng mới, bấm vào dòng để tua tới đó.
struct LyricsLinesView: View {
    @ObservedObject var store: LyricsStore
    let size: CGFloat
    let spacing: CGFloat
    var compact = false
    var fullscreen = false

    var body: some View {
        switch store.status {
        case .synced, .plain:
            lines
        case .loading, .idle:
            message(L("Đang tìm lời…", "Looking for lyrics…"))
        case .missing:
            message(store.track?.duration ?? 0 <= 0
                    ? L("Đang phát trực tiếp, không có lời", "Live stream, no lyrics")
                    : store.enabled ? L("Chưa có lời cho bài này", "No lyrics for this song yet")
                                    : L("Lời bài hát đang tắt trong Cài đặt", "Lyrics are turned off in Settings"))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.ui(fullscreen ? 26 : 13, weight: .medium))
            .foregroundStyle(LyricsStyle.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fullscreen ? .leading : .center)
    }

    @ViewBuilder private var lines: some View {
        if store.status == .synced {
            SyncedLyricsView(store: store, size: size, spacing: spacing, compact: compact, fullscreen: fullscreen)
                .mask(fadeMask)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: spacing) {
                    // Như Spotify: báo trước là lời này không chạy theo nhạc.
                    Text(L("Lời bài hát này chưa được đồng bộ với nhạc.", "These lyrics aren't synced to the song yet."))
                        .font(.ui(max(size * 0.55, 11), weight: .semibold))
                        .foregroundStyle(fullscreen ? .white.opacity(0.5) : LyricsStyle.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, spacing * 0.5)
                    ForEach(store.lines) { line in
                        Text(line.text)
                            .font(.ui(size, weight: .semibold))
                            .foregroundStyle(fullscreen ? .white.opacity(0.75) : LyricsStyle.ink.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, fullscreen ? 280 : compact ? 4 : 40)
                .padding(.bottom, fullscreen ? 280 : 40)
            }
            .mask(compact ? AnyView(bottomFadeMask) : AnyView(fadeMask))
        }
    }

    /// Trong notch lời bắt đầu ngay dưới tên bài: chỉ mờ dần ở mép dưới.
    private var bottomFadeMask: some View {
        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                               .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

private struct LyricHeights: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Lời đồng bộ kiểu Apple Music: không cuộn cả khối, mỗi dòng tự trượt bằng lò xo, dòng dưới trễ hơn dòng trên
/// một chút nên cả đoạn "gợn" như sóng. Dòng đang hát phóng to bằng scale (đổi cỡ chữ sẽ giật).
struct SyncedLyricsView: View {
    @ObservedObject var store: LyricsStore
    let size: CGFloat
    let spacing: CGFloat
    var compact = false
    var fullscreen = false
    private var heights = State(initialValue: [Int: CGFloat]())

    init(store: LyricsStore, size: CGFloat, spacing: CGFloat, compact: Bool = false, fullscreen: Bool = false) {
        self.store = store
        self.size = size
        self.spacing = spacing
        self.compact = compact
        self.fullscreen = fullscreen
    }

    var body: some View {
        GeometryReader { geo in
            let cur = store.current ?? 0
            let shift = geo.size.height * (fullscreen ? 0.4 : 0.42) - top(of: cur)
            metal(VStack(alignment: .leading, spacing: spacing) {
                ForEach(store.lines) { line in
                    row(line, cur: cur, width: geo.size.width)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: LyricHeights.self, value: [line.id: g.size.height])
                        })
                        .offset(y: shift)
                        .animation(.spring(response: 0.7, dampingFraction: 0.86).delay(delay(line.id, cur)), value: cur)
                        // Animation từ ngoài (bật/tắt lời, notch đổi cỡ) không được kéo các dòng chạy theo.
                        .transaction { $0.animation = nil }
                }
            }
            // drawingGroup cắt theo khung khối chữ: chừa chỗ cho dòng bị đẩy xuống (bài ít dòng, đầu bài).
            .padding(.bottom, fullscreen ? geo.size.height : 0))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // Chưa đo xong chiều cao các dòng thì vị trí còn ước lượng: ẩn để khỏi giật.
            .opacity(heights.wrappedValue.count >= store.lines.count ? 1 : 0)
        }
        .clipped()
        // clipped() chỉ cắt phần vẽ: dòng đã trượt ra ngoài vẫn nhận chuột, đè lên nút ở header.
        .contentShape(Rectangle())
        .onPreferenceChange(LyricHeights.self) { heights.wrappedValue = $0 }
    }

    private func row(_ line: LyricLine, cur: Int, width: CGFloat) -> some View {
        let isCurrent = line.id == store.current
        let distance = abs(line.id - cur)
        let grow: CGFloat = fullscreen ? 1.04 : compact ? 1.1 : 1.06
        return lineText(line, isCurrent: isCurrent)
            .fixedSize(horizontal: false, vertical: true)
            // Ngắt dòng theo bề rộng đã trừ phần phóng to: dòng dài đang hát không tràn mép phải
            // (drawingGroup / clipped cắt mất chữ), và dòng không ngắt lại khi tới lượt hát.
            .frame(width: max(floor(width / grow) - 2, 0), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isCurrent ? grow : 1, anchor: .leading)
            .blur(radius: fullscreen ? min(CGFloat(distance), 4) * 0.45 : 0)
            .contentShape(Rectangle())
            .onTapGesture { store.seek(to: line) }
            .allowsHitTesting(distance <= 6)
    }

    @ViewBuilder private func lineText(_ line: LyricLine, isCurrent: Bool) -> some View {
        // Karaoke: mọi dòng cùng một kiểu view (chỉ dòng đang hát chạy đồng hồ), nên vào / ra dòng chuyển mượt.
        if fullscreen, store.karaoke, let start = line.time, let track = store.track {
            let next = store.lines.first { $0.id > line.id && $0.time != nil }?.time
            KaraokeLine(text: line.text, start: start, end: next, track: track, size: size,
                        delay: store.audioDelay, active: isCurrent)
        } else {
            Text(line.text)
                .font(.ui(size, weight: .bold))
                .foregroundStyle(isCurrent ? (fullscreen ? .white : LyricsStyle.active)
                                 : (fullscreen ? .white.opacity(0.3) : LyricsStyle.dim))
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.4), value: isCurrent)
        }
    }

    /// Toàn màn hình: chữ lớn + blur động, vẽ qua Metal cho khỏi rớt khung hình.
    @ViewBuilder private func metal<V: View>(_ v: V) -> some View {
        if fullscreen { v.drawingGroup() } else { v }
    }

    /// Đỉnh dòng `index` tính từ đầu khối (chỉ dùng chiều cao đo được, không phụ thuộc offset).
    private func top(of index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { $0 + (heights.wrappedValue[$1] ?? size * 1.3) + spacing }
    }

    /// Dòng ở trên và dòng đang hát đi trước, mỗi dòng phía dưới trễ thêm một nhịp.
    private func delay(_ id: Int, _ cur: Int) -> Double {
        Double(min(max(id - cur + 1, 0), 8)) * 0.035
    }
}

/// Karaoke dưới nút điều khiển ở màn hình lời toàn màn hình: nút tô dần từng chữ (chỉ khi lời có mốc thời gian),
/// bật rồi thì có thanh Giọng ca sĩ. Hạ giọng cần quyền Ghi âm thanh hệ thống và macOS hiện chấm tím suốt lúc đó.
/// Rời màn hình lời thì tự tắt.
struct KaraokeButton: View {
    @ObservedObject var store: LyricsStore
    @ObservedObject private var sound = SoundCenter.shared
    @ObservedObject private var ai = AIVocals.shared
    private var deniedState = State(initialValue: false)

    init(store: LyricsStore) { self.store = store }


    var body: some View {
        VStack(spacing: 12) {
            toggle
            if store.karaoke { vocals.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: store.karaoke)
        // Engine không nghe được tiếng (chưa cấp quyền) thì đã gỡ tap: kéo thanh về cho khớp, nói rõ vì sao.
        .onChange(of: sound.permissionDenied) { _, value in
            if value && store.vocalLevel < 1 { store.vocalLevel = 1; deniedState.wrappedValue = true }
        }
        .onChange(of: store.vocalLevel) { _, v in if v < 1 { deniedState.wrappedValue = false } }
        .onDisappear { store.karaoke = false }
    }

    @ViewBuilder private var vocals: some View {
        if !ai.installed { modelDownload } else { vocalControls }
    }

    private var note: (String) -> Text = { Text($0).font(.ui(11)).foregroundStyle(.white.opacity(0.55)) }

    private var modelDownload: some View {
        VStack(alignment: .leading, spacing: 6) {
            note(L("Tắt giọng ca sĩ cần model AI (33 MB, tải một lần từ huggingface.co, chạy hoàn toàn trên máy).",
                   "Removing the vocals needs an AI model (33 MB, downloaded once from huggingface.co, runs entirely on this Mac)."))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(ai.download == .failed ? L("Thử tải lại", "Try again") : L("Tải model", "Download model")) {
                    ai.downloadModel()
                }
                .buttonStyle(.plain).font(.ui(12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.16)))
                .disabled(ai.download == .running)
                if ai.download == .running { ProgressView().controlSize(.small); note(L("Đang tải…", "Downloading…")) }
                if ai.download == .failed { note(L("Tải không được, kiểm tra mạng.", "Download failed, check your connection.")) }
            }
        }
    }

    private var vocalControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: store.vocalLevel < 1 ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    .frame(width: 18)
                Text(L("Giọng ca sĩ", "Vocals")).font(.ui(13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Slider(value: Binding(get: { store.vocalLevel },
                                      set: { store.vocalLevel = $0 > 0.97 ? 1 : $0 }), in: 0...1)
                    .tint(.white)
                    .disabled(ai.state != .on)
                    .accessibilityLabel(L("Mức giọng ca sĩ", "Vocal level"))
                Text("\(Int((store.vocalLevel * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 38, alignment: .trailing)
            }
            .help(L("Kéo xuống để hạ giọng ca sĩ (V)", "Drag down to lower the vocals (V)"))
            Toggle(isOn: $store.guideHard) {
                Text(L("Giọng dẫn ở câu khó", "Guide vocals on hard lines"))
                    .font(.ui(12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .toggleStyle(.switch).controlSize(.mini).tint(.white.opacity(0.5))
            .help(L("Câu hát nhanh, dày chữ thì giọng ca sĩ hát nhỏ để dẫn bạn",
                    "On fast, wordy lines the singer comes back softly to guide you"))
            if ai.state == .loading {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); note(L("Đang chuẩn bị AI, vài giây…", "Getting the AI ready, a few seconds…")) }
            } else if ai.state == .failed {
                note(L("Không nạp được model AI.", "Couldn't load the AI model."))
            }
            if deniedState.wrappedValue {
                Text(L("Cần quyền Ghi âm thanh hệ thống để hạ giọng ca sĩ.",
                       "Lowering the vocals needs System Audio Recording permission."))
                    .font(.ui(11)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                Button(L("Mở Cài đặt hệ thống", "Open System Settings")) { sound.openPrivacySettings() }
                    .buttonStyle(.plain).font(.ui(11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
        }
    }

    private var toggle: some View {
        let synced = store.status == .synced
        return Button { store.karaoke.toggle() } label: {
            Label(L("Karaoke", "Karaoke"), systemImage: store.karaoke ? "music.mic.circle.fill" : "music.mic")
                .font(.ui(13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(store.karaoke ? 0.28 : 0.12)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!synced)
        .opacity(synced ? 1 : 0.4)
        .help(!synced ? L("Bài này chưa có lời đồng bộ theo nhạc", "This song has no synced lyrics")
              : store.karaoke ? L("Tắt karaoke (K)", "Turn karaoke off (K)")
                              : L("Tô từng chữ theo nhạc (K)", "Highlight the words as they're sung (K)"))
        .accessibilityLabel(store.karaoke ? L("Tắt karaoke", "Turn karaoke off") : L("Bật karaoke", "Turn karaoke on"))
    }
}

/// Dòng karaoke kiểu Apple Music: dòng đang hát tô sáng dần từng ký tự, mép tô mềm (~3 ký tự), 60 khung/giây;
/// hát xong thì mờ dần về như dòng thường. LRCLIB chỉ có mốc theo dòng nên tốc độ tô là ước lượng theo số ký tự,
/// trong khoảng tới dòng sau. Ghép bằng `Text + Text` nên dòng dài vẫn tự xuống dòng.
struct KaraokeLine: View {
    let text: String
    let start: Double
    let end: Double?
    let track: Track
    let size: CGFloat
    /// Trễ âm thanh + chỉnh tay (LyricsStore.heardPosition).
    let delay: Double
    let active: Bool

    static let dim = 0.3, unsung = 0.38, edge = 3.0

    var body: some View {
        // Dòng không hát hoặc nhạc dừng: đồng hồ đứng, không vẽ lại.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || !track.isPlaying)) { ctx in
            Self.render(Array(text), lit: active ? lit(at: track.position(at: ctx.date) - delay) : nil)
                .font(.ui(size, weight: .bold))
        }
        .contentTransition(.interpolate)
        .animation(.easeOut(duration: 0.45), value: active)
    }

    /// Bao nhiêu ký tự đã tô (có phần lẻ).
    private func lit(at pos: Double) -> Double {
        let chars = Double(text.count)
        guard chars > 0 else { return 0 }
        let gap = (end ?? start + 6) - start
        // shortcut: tốc độ hát ước lượng ~0,085 giây/ký tự; lời có mốc từng chữ (Apple Music) thì nên dùng mốc thật.
        let duration = max(0.3, min(gap * 0.92, chars * 0.085 + 0.6))
        // Chạy tới hết cả mép mềm để ký tự cuối sáng hẳn.
        return min(max((pos - start) / duration, 0), 1) * (chars + Self.edge)
    }

    /// `lit` nil = dòng không hát (mờ đều). Ký tự đủ sáng / chưa tô gộp thành một mẩu, chỉ mép mềm tách lẻ.
    static func render(_ chars: [Character], lit: Double?) -> Text {
        func level(_ i: Int) -> Double {
            guard let lit else { return dim }
            let f = min(max((lit - Double(i)) / edge, 0), 1)
            return unsung + (1 - unsung) * f
        }
        var out = Text("")
        var run = "", runLevel = -1.0
        for (i, c) in chars.enumerated() {
            let l = (level(i) * 100).rounded() / 100
            if l != runLevel, !run.isEmpty {
                out = out + Text(run).foregroundColor(.white.opacity(runLevel))
                run = ""
            }
            runLevel = l
            run.append(c)
        }
        if !run.isEmpty { out = out + Text(run).foregroundColor(.white.opacity(runLevel)) }
        return out
    }
}

// MARK: - Toàn màn hình

private final class LyricsWindow: NSWindow {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()                                            // Esc
        case 49: LyricsFullscreen.shared.media?.playPause()             // Space
        case 40: LyricsStore.shared.karaoke.toggle()                     // K: karaoke (tô chữ)
        case 9 where LyricsStore.shared.karaoke:                         // V: hạ / trả giọng ca sĩ
            let s = LyricsStore.shared
            s.vocalLevel = s.vocalLevel < 1 ? 1 : LyricsStore.karaokeVocalLevel
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class LyricsFullscreen {
    static let shared = LyricsFullscreen()
    private var window: LyricsWindow?
    fileprivate weak var media: NowPlaying?

    func show(media: NowPlaying) {
        self.media = media
        if let window { window.makeKeyAndOrderFront(nil); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let w = LyricsWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .mainMenu + 1
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.onClose = { [weak self] in self?.close() }
        w.contentView = NSHostingView(rootView: LyricsFullscreenView(media: media, close: { [weak self] in self?.close() }))
        w.setFrame(screen.frame, display: true)
        w.alphaValue = 0
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; w.animator().alphaValue = 1 }
    }

    func close() {
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { w.orderOut(nil); w.contentView = nil }
        }
    }
}

struct LyricsFullscreenView: View {
    @ObservedObject var media: NowPlaying
    @ObservedObject var store = LyricsStore.shared
    let close: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                DriftingArtwork(image: media.artwork)
                    .ignoresSafeArea()
                Color.black.opacity(0.32).ignoresSafeArea()
                HStack(alignment: .center, spacing: geo.size.width * 0.06) {
                    side(width: min(geo.size.width * 0.28, 380))
                    LyricsLinesView(store: store, size: min(max(geo.size.width / 42, 26), 42), spacing: 22, fullscreen: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, geo.size.width * 0.08)
                .padding(.vertical, 60)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .padding(28)
                .help(L("Đóng (Esc)", "Close (Esc)"))
            }
        }
        .environment(\.locale, SettingsStore.shared.locale)
        .onAppear { store.bind(media); store.attach() }
        .onDisappear { store.detach() }
    }

    private func side(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Artwork(image: media.artwork, corner: 14)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .overlay(alignment: .bottomTrailing) {
                    if let track = media.track {
                        SourceBadge(bundleID: track.bundleID, size: 40, open: media.openPlayer).offset(x: 10, y: 10)
                    }
                }
            if let track = media.track {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.ui(26, weight: .bold)).foregroundStyle(.white)
                    Text(track.artist).font(.ui(18)).foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(2)
                if track.duration > 0 {
                    LiveProgressBar(track: track, accent: .white, knob: false, override: nil)
                        .frame(height: 5)
                    HStack {
                        TimelineView(SecondTicks(track: track)) { ctx in
                            Text(ProgressRow.format(track.position(at: ctx.date)))
                        }
                        Spacer()
                        Text(ProgressRow.format(track.duration))
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                }
                HStack(spacing: media.modes == nil ? 34 : 14) {
                    if let modes = media.modes {
                        ModeButton(kind: .shuffle, modes: modes, plain: true, side: 34, action: media.toggleShuffle)
                    }
                    control("backward.fill", 22, media.previous)
                    control(track.isPlaying ? "pause.fill" : "play.fill", 32, media.playPause)
                    control("forward.fill", 22, media.next)
                    if let modes = media.modes {
                        ModeButton(kind: .repeatMode, modes: modes, plain: true, side: 34, action: media.cycleRepeat)
                    }
                }
                .frame(width: width)
                .padding(.top, 4)
                KaraokeButton(store: store)
                    .frame(width: width)
            }
        }
        .frame(width: width)
    }

    private func control(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white)
                .frame(width: size * 2, height: size * 1.8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Nền: ảnh bìa làm mờ thật mạnh, xoay và phóng chậm bằng Core Animation (chạy ở render server).
struct DriftingArtwork: NSViewRepresentable {
    let image: NSImage?

    func makeNSView(context: Context) -> DriftingArtworkView { DriftingArtworkView() }
    func updateNSView(_ view: DriftingArtworkView, context: Context) { view.set(image) }
}

final class DriftingArtworkView: NSView {
    private let blobs = (0..<2).map { _ in CALayer() }
    private weak var current: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for (i, b) in blobs.enumerated() {
            b.contentsGravity = .resizeAspectFill
            b.opacity = i == 0 ? 1 : 0.6
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ image: NSImage?) {
        guard image !== current else { return }
        current = image
        let blurred = image.flatMap(Self.blur)
        for b in blobs { b.contents = blurred }
    }

    override func layout() {
        super.layout()
        let side = max(bounds.width, bounds.height) * 1.6
        for (i, b) in blobs.enumerated() {
            b.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            b.position = CGPoint(x: bounds.midX + (i == 0 ? -1 : 1) * bounds.width * 0.18, y: bounds.midY)
            guard b.animation(forKey: "spin") == nil else { continue }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (i == 0 ? 1 : -1) * Double.pi * 2
            spin.duration = i == 0 ? 120 : 90
            spin.repeatCount = .infinity
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 1.18
            breathe.duration = 17
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            for a in [spin, breathe] as [CABasicAnimation] {
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
                b.add(a, forKey: a === spin ? "spin" : "breathe")
            }
        }
    }

    private static func blur(_ image: NSImage) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let small = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 160 / CGFloat(cg.width), y: 160 / CGFloat(cg.width)))
        let out = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.5, kCIInputBrightnessKey: -0.05])
            .cropped(to: small.extent)
        return CIContext().createCGImage(out, from: small.extent)
    }
}

/// Dòng bật/tắt trong Cài đặt › Tab.
struct LyricsSettingsToggle: View {
    @ObservedObject var store = LyricsStore.shared
    var body: some View {
        Toggle(L("Lời bài hát (LRCLIB)", "Lyrics (LRCLIB)"), isOn: $store.enabled)
    }
}
