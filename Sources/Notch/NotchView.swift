import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var media: NowPlaying
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var tray: TrayStore
    @ObservedObject var calendar: CalendarStore

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    // Không dùng macro @Namespace/@State (plugin chỉ có trong Xcode).
    private var ns = Namespace()

    var body: some View {
        let size = model.shapeSize(playing: media.hasTrack)
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius)
        let notch = model.notchSize

        // Nội dung có kích thước cố định ở trạng thái cuối; khung shape lớn dần và "lộ" nó ra
        // thay vì layout lại chữ ở mỗi frame animation.
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if model.expanded {
                ExpandedView(model: model, media: media, permissions: permissions, tray: tray,
                             calendar: calendar, notchHeight: notch.height, ns: ns.wrappedValue)
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
        .overlay(shape.stroke(Color.white.opacity(model.expanded ? 0.08 : 0), lineWidth: 1))
        .shadow(color: .black.opacity(model.expanded ? 0.6 : 0), radius: 18, y: 8)
        .animation(spring, value: model.expanded)
        .animation(spring, value: model.tall)
        .animation(spring, value: model.chargePeek)
        .animation(spring, value: media.hasTrack)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, Locale(identifier: "vi_VN"))
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
            Artwork(image: media.artwork, corner: 6)
                .frame(width: height - 12, height: height - 12)
                .matchedGeometryEffect(id: "artwork", in: ns)
                .frame(width: height, height: height)
            Spacer(minLength: 0)
            Group {
                if media.isPlaying {
                    EqualizerBars(active: true, color: media.accent)
                } else {
                    // Tạm dừng: nốt nhạc đứng yên thay cho sóng.
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .semibold))
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(green)
                Text(peek.charging ? "Đang sạc" : "Đã cắm sạc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(width: wing)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("\(peek.percent)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
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
    let notchHeight: CGFloat
    let ns: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TabPill(symbol: "music.note", label: nil, selected: model.tab == .media) {
                    model.tab = .media
                }
                TabPill(symbol: "tray.full", label: tray.files.isEmpty ? nil : "\(tray.files.count)",
                        selected: model.tab == .tray) {
                    model.tab = .tray
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Thoát Notch")
            }
            .padding(.horizontal, 18)
            .frame(height: notchHeight)

            if let request = permissions.current, let questions = request.questions, !questions.isEmpty {
                QuestionCard(request: request, questions: questions,
                             answer: { permissions.answer(request, $0) },
                             dismiss: { permissions.dismiss(request) })
                    .id(request.id)
                    .transition(.opacity)
            } else if let request = permissions.current {
                PermissionCard(request: request, pending: permissions.requests.count) {
                    permissions.resolve(request, $0)
                }
                .id(request.id)
                .transition(.opacity)
            } else if model.tab == .tray || model.dropTargeted {
                TrayView(tray: tray, targeted: model.dropTargeted)
            } else {
                HStack(spacing: 0) {
                    Group {
                        if let track = media.track {
                            PlayerView(media: media, track: track, ns: ns)
                        } else {
                            Text("Không có nhạc đang phát")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 340)
                    Rectangle().fill(.white.opacity(0.08))
                        .frame(width: 1)
                        .padding(.bottom, 16)
                    CalendarWidget(calendar: calendar)
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
            tray.accept(providers)
            model.tab = .tray
            return true
        }
    }
}

struct TabPill: View {
    let symbol: String
    let label: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if let label { Text(label) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0)))
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
        HStack(spacing: 14) {
            Artwork(image: media.artwork, corner: 12)
                .frame(width: 72, height: 72)
                .matchedGeometryEffect(id: "artwork", in: ns)
                .background(ArtworkGlow(image: media.artwork))
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }
                .help("Mở \(track.player.rawValue)")

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }

                ProgressRow(track: track, accent: media.accent)

                HStack(spacing: 26) {
                    ControlButton(symbol: "backward.fill", size: 14, action: media.previous)
                    ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 18, action: media.playPause)
                    ControlButton(symbol: "forward.fill", size: 14, action: media.next)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
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
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(accent).frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 4)
                Text(Self.format(track.duration))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
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
                .foregroundStyle(.white)
                .frame(width: 32, height: 28)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
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
            RoundedRectangle(cornerRadius: corner).fill(.white.opacity(0.1))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
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
            bar.cornerRadius = Self.barWidth / 2
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

