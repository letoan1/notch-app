import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var tray: TrayStore
    @ObservedObject var calendar: CalendarStore
    let camera: CameraMirror
    @ObservedObject var settings: SettingsStore

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    // Không dùng macro @Namespace/@State (plugin chỉ có trong Xcode).
    private var ns = Namespace()

    var body: some View {
        let size = model.shapeSize(playing: media.hasTrack)
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius,
                               pixel: Theme.isPixel && model.expanded)
        let notch = model.notchSize

        // Nội dung có kích thước cố định ở trạng thái cuối; khung shape lớn dần và "lộ" nó ra
        // thay vì layout lại chữ ở mỗi frame animation.
        ZStack(alignment: .top) {
            shape.fill(Theme.isCassette ? CassettePalette.background : Color.black)
            if model.expanded {
                ExpandedView(model: model, media: media, permissions: permissions, tray: tray,
                             calendar: calendar, camera: camera, settings: settings,
                             notchHeight: notch.height, ns: ns.wrappedValue)
                    .frame(width: NotchModel.expandedWidth - 28,
                           height: notch.height + model.expandedBodyHeight)
                    .transition(.notchContent)
            } else if let peek = model.chargePeek {
                ChargeWings(peek: peek, wing: NotchModel.peekWing)
                    .frame(width: notch.width + NotchModel.peekWing * 2, height: notch.height)
                    .transition(.notchContent)
            } else if media.hasTrack {
                CollapsedWings(media: media, height: notch.height, ns: ns.wrappedValue)
                    .frame(width: notch.width + notch.height * 2, height: notch.height)
                    .transition(.notchContent)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.isPixel ? PixelPalette.border.opacity(model.expanded ? 1 : 0) : Color.white.opacity(model.expanded ? 0.08 : 0),
                              lineWidth: Theme.isPixel ? 3 : 1))
        .shadow(color: .black.opacity(model.expanded ? 0.6 : 0), radius: 18, y: 8)
        .animation(spring, value: model.expanded)
        .animation(spring, value: model.tall)
        .animation(spring, value: model.mirrorMode)
        .animation(spring, value: model.chargePeek)
        .animation(spring, value: media.hasTrack)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, settings.locale)
        .textCase(Theme.isPixel ? .uppercase : nil)
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Hiện: mờ → rõ + phóng nhẹ, trễ một nhịp sau khi khung bắt đầu phình. Ẩn: tắt nhanh.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0))
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.92, anchor: .top))
                .animation(.spring(response: 0.4, dampingFraction: 0.86).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }
}

// MARK: - Collapsed

struct CollapsedWings: View {
    @ObservedObject var media: NowPlaying
    let height: CGFloat
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if Theme.isCassette {
                    MiniTape(band: CassettePalette.band, name: "")
                        .frame(width: height - 8, height: (height - 8) * 0.66)
                } else {
                    Artwork(image: media.artwork, corner: 6)
                        .frame(width: height - 12, height: height - 12)
                        .matchedGeometryEffect(id: "artwork", in: ns)
                }
            }
            .frame(width: height, height: height)
            Spacer(minLength: 0)
            Group {
                if Theme.isCassette {
                    HStack(spacing: 3) {
                        MiniReel(spinning: media.isPlaying).frame(width: 13, height: 13)
                        MiniReel(spinning: media.isPlaying).frame(width: 13, height: 13)
                    }
                } else if media.isPlaying {
                    EqualizerBars(active: true, color: media.accent)
                } else {
                    // Tạm dừng: nốt nhạc đứng yên thay cho sóng.
                    Image(systemName: "music.note")
                        .font(.ui(9, weight: .semibold))
                        .foregroundStyle(media.accent.opacity(0.85))
                }
            }
            .transition(.opacity)
            .frame(width: height, height: height)
        }
    }
}

struct ChargeWings: View {
    let peek: NotchModel.ChargePeek
    let wing: CGFloat

    private let green = Color(red: 0.30, green: 0.85, blue: 0.40)

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.ui(11, weight: .bold))
                    .foregroundStyle(green)
                Text(peek.charging ? L("Đang sạc", "Charging") : L("Đã cắm sạc", "Plugged in"))
                    .font(Theme.isCassette ? .hand(13) : .ui(11, weight: .semibold))
                    .foregroundStyle(Theme.isCassette ? CassettePalette.ink : .white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.isCassette ? 6 : 0)
            .padding(.vertical, Theme.isCassette ? 2 : 0)
            .background(Theme.isCassette ? CassettePalette.note : Color.clear)
            .rotationEffect(.degrees(Theme.isCassette ? -2 : 0))
            .frame(width: wing)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("\(peek.percent)%")
                    .font(.ui(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(green)
                BatteryGlyph(level: Double(peek.percent) / 100, color: green)
            }
            .frame(width: wing)
        }
    }
}

private struct BatteryGlyph: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                    .frame(width: 24, height: 12)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, 20 * level), height: 8)
                    .padding(.leading, 2)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var tray: TrayStore
    @ObservedObject var calendar: CalendarStore
    let camera: CameraMirror
    @ObservedObject var settings: SettingsStore
    let notchHeight: CGFloat
    let ns: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                let tabs = settings.enabledTabs
                if tabs.contains(.media) {
                    TabPill(symbol: settings.showMedia ? "music.note" : "calendar", label: nil,
                            selected: model.tab == .media) {
                        model.tab = .media
                    }
                }
                if tabs.contains(.tray) {
                    TabPill(symbol: "tray.full.fill", label: nil, selected: model.tab == .tray,
                            badge: tray.files.isEmpty ? nil : tray.files.count) {
                        model.tab = .tray
                    }
                }
                if tabs.contains(.mirror) {
                    TabPill(symbol: "camera.fill", label: nil, selected: model.tab == .mirror) {
                        model.tab = .mirror
                    }
                }
                Spacer()
                Button { SettingsWindowController.shared.show() } label: {
                    ThemedIcon(symbol: "gearshape.fill")
                        .font(.ui(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Cài đặt", "Settings"))
                Button { NSApp.terminate(nil) } label: {
                    ThemedIcon(symbol: "power")
                        .font(.ui(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(L("Thoát Notch", "Quit Notch"))
            }
            .padding(.horizontal, 18)
            .frame(height: notchHeight)

            if let request = permissions.current, let questions = request.questions, !questions.isEmpty {
                QuestionCard(request: request, questions: questions,
                             answer: { permissions.answer(request, $0) },
                             dismiss: { permissions.dismiss(request) })
                    .background { if Theme.isCassette { Corkboard().padding(.horizontal, 10).padding(.bottom, 6) } }
                    .id(request.id)
                    .transition(.opacity)
            } else if let request = permissions.current {
                Group {
                    if Theme.isCassette {
                        CassettePermissionCard(request: request, pending: permissions.requests.count) {
                            permissions.resolve(request, $0)
                        }
                    } else {
                        PermissionCard(request: request, pending: permissions.requests.count) {
                            permissions.resolve(request, $0)
                        }
                    }
                }
                .id(request.id)
                .transition(.opacity)
            } else if settings.showTray && (model.tab == .tray || model.dropTargeted) {
                if Theme.isCassette {
                    CassetteTrayView(tray: tray, targeted: model.dropTargeted)
                } else {
                    TrayView(tray: tray, targeted: model.dropTargeted)
                }
            } else if settings.showMirror && model.tab == .mirror {
                if Theme.isCassette {
                    CassetteMirrorView(camera: camera, calendar: calendar)
                } else {
                    MirrorView(camera: camera, calendar: calendar)
                }
            } else if settings.enabledTabs.isEmpty {
                Text(L("Bật ít nhất một tab trong Cài đặt ⚙️", "Turn on at least one tab in Settings ⚙️"))
                    .font(.ui(13))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    if settings.showMedia {
                    Group {
                        if Theme.isCassette {
                            CassettePlayerView(media: media)
                        } else if let track = media.track {
                            PlayerView(media: media, track: track, ns: ns)
                        } else {
                            Text(L("Không có nhạc đang phát", "Nothing playing"))
                                .font(.ui(13))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: settings.showCalendar ? 350 : nil)
                    .frame(maxWidth: settings.showCalendar ? nil : .infinity)
                    }
                    if settings.showMedia && settings.showCalendar {
                        Rectangle().fill(.white.opacity(0.08))
                            .frame(width: 1)
                            .padding(.bottom, 16)
                    }
                    if settings.showCalendar {
                        if Theme.isCassette {
                            NoteCalendar(calendar: calendar)
                        } else {
                            CalendarWidget(calendar: calendar)
                        }
                    }
                }
            }
        }
        // Neo lên trên: tab nào thấp hơn thì hàng tab cũng không bị đẩy xuống.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Thả file vào bất kỳ đâu trên notch đang mở đều vào khay.
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { model.dropTargeted },
            set: { model.dropTargeted = $0 }
        )) { providers in
            guard settings.showTray else { return false }
            tray.accept(providers)
            model.tab = .tray
            return true
        }
    }
}

struct TabPill: View {
    let symbol: String?
    let label: String?
    let selected: Bool
    var badge: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { ThemedIcon(symbol: symbol) }
                if let label { Text(label) }
            }
            .font(.ui(11, weight: .semibold))
            .foregroundStyle(Theme.isCassette ? CassettePalette.ink : .white.opacity(selected ? 0.95 : 0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(TabBackground(selected: selected))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text("\(badge)")
                        .font(.ui(8, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(.white.opacity(0.9)))
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PlayerView: View {
    @ObservedObject var media: NowPlaying
    let track: Track
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 20) {
            Artwork(image: media.artwork, corner: 18)
                .frame(width: 104, height: 104)
                .matchedGeometryEffect(id: "artwork", in: ns)
                .background(ArtworkGlow(image: media.artwork))
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }
                .help(L("Mở \(track.player.rawValue)", "Open \(track.player.rawValue)"))

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.ui(17, weight: .bold))
                        .foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Text(track.artist)
                            .font(.ui(14))
                            .foregroundStyle(.white.opacity(0.6))
                        if track.isPlaying {
                            EqualizerBars(active: true, color: media.accent)
                                .frame(width: 16, height: 14)
                        }
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }

                ProgressRow(track: track, accent: media.accent)

                HStack(spacing: 14) {
                    ControlButton(symbol: "backward.fill", size: 18, action: media.previous)
                    ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 24, action: media.playPause)
                    ControlButton(symbol: "forward.fill", size: 18, action: media.next)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }
}

struct ProgressRow: View {
    let track: Track
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let pos = track.position(at: ctx.date)
            let ratio = track.duration > 0 ? pos / track.duration : 0
            HStack(spacing: 8) {
                Text(Self.format(pos))
                GeometryReader { geo in
                    if Theme.isPixel {
                        PixelSegments(ratio: ratio, accent: PixelPalette.pink)
                    } else {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule()
                            .fill(LinearGradient(colors: [accent.opacity(0.75), accent],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * ratio)
                    }
                    }
                }
                .frame(height: 5)
                Text(Self.format(track.duration))
            }
            .font(.ui(11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    // Không dùng macro @State: plugin SwiftUIMacros chỉ có trong Xcode, CLT không có.
    private var hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.isPixel ? Color.black : .white)
                .frame(width: Theme.isPixel ? 52 : 38, height: Theme.isPixel ? 38 : 34)
                .background(Theme.isPixel
                    ? AnyView(PixelKey(fill: symbol.hasPrefix("pause") || symbol.hasPrefix("play") ? Color(red: 1, green: 0.9, blue: 0.43) : PixelPalette.border))
                    : AnyView(Circle().fill(.white.opacity(hovering ? 0.12 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }
}

// MARK: - Shared

struct Artwork: View {
    let image: NSImage?
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.isPixel ? 2 : corner).fill(.white.opacity(0.1))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.isPixel ? 2 : corner))
        // Pixel: giữ ảnh bìa nguyên nét (pixel hoá ảnh chụp thật trông như vỡ ảnh), chỉ thêm khung vuông.
        .overlay(Theme.isPixel ? RoundedRectangle(cornerRadius: 2).strokeBorder(PixelPalette.border, lineWidth: 4) : nil)
        .background(Theme.isPixel ? Rectangle().fill(PixelPalette.shadow).offset(x: 4, y: 4) : nil)
        .animation(.easeOut(duration: 0.25), value: image)
    }
}

/// Sóng nhạc bằng Core Animation: animation chạy trong render server, app không phải
/// dựng lại view mỗi frame (bản SwiftUI repeatForever tốn ~7–15% CPU khi đang phát).
struct EqualizerBars: NSViewRepresentable {
    let active: Bool
    let color: Color

    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView() }

    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.update(color: NSColor(color), active: active)
    }
}

final class EqualizerLayerView: NSView {
    private static let speeds: [Double] = [0.42, 0.31, 0.5, 0.36]
    private static let barWidth: CGFloat = 2, gap: CGFloat = 1.5, barHeight: CGFloat = 9
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = Theme.isPixel ? 0 : Self.barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = Self.barWidth * 4 + Self.gap * 3
        let x0 = (bounds.width - total) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight)
            bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2,
                                   y: bounds.midY)
        }
        CATransaction.commit()
    }

    func update(color: NSColor, active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        for (i, bar) in bars.enumerated() {
            if active, bar.animation(forKey: "eq") == nil {
                let anim = CABasicAnimation(keyPath: "transform.scale.y")
                anim.fromValue = 0.3
                anim.toValue = 1
                anim.duration = Self.speeds[i]
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(anim, forKey: "eq")
            } else if !active {
                bar.removeAnimation(forKey: "eq")
            }
        }
    }
}

/// Quầng sáng mờ từ chính ảnh bìa, đặt sau artwork.
struct ArtworkGlow: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable()
                .blur(radius: 22)
                .opacity(0.55)
                .scaleEffect(1.15)
        }
    }
}

