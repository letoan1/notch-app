import AppKit
import QuartzCore
import SwiftUI

/// Chữ "hello" viết tay một nét liền (tự vẽ, hệ toạ độ 198 × 86, đường chân chữ y = 78).
struct HelloPath: Shape {
    static let box = CGSize(width: 198, height: 86)

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / Self.box.width, rect.height / Self.box.height)
        let ox = rect.midX - Self.box.width * s / 2, oy = rect.midY - Self.box.height * s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        path.move(to: p(6, 70))
        for c in Self.curves {
            path.addCurve(to: p(c.2.0, c.2.1), control1: p(c.0.0, c.0.1), control2: p(c.1.0, c.1.1))
        }
        return path
    }

    private typealias Pt = (CGFloat, CGFloat)
    /// (điểm điều khiển 1, điểm điều khiển 2, điểm đến) nối tiếp nhau.
    private static let curves: [(Pt, Pt, Pt)] = [
        // h: nét lên, vòng khuyết trên, thân xuống, bướu
        ((18, 62), (34, 40), (40, 24)), ((44, 12), (40, 6), (34, 8)), ((28, 10), (24, 40), (20, 78)),
        ((24, 62), (32, 50), (42, 50)), ((50, 50), (50, 60), (50, 70)), ((50, 76), (54, 79), (60, 77)),
        // e
        ((70, 73), (82, 64), (82, 56)), ((82, 49), (76, 47), (72, 50)), ((66, 54), (66, 68), (70, 74)),
        ((74, 79), (84, 79), (92, 74)),
        // l
        ((102, 66), (114, 40), (116, 24)), ((118, 12), (114, 6), (110, 8)), ((104, 11), (100, 40), (100, 66)),
        ((100, 76), (106, 80), (114, 76)),
        // l
        ((124, 66), (136, 40), (138, 24)), ((140, 12), (136, 6), (132, 8)), ((126, 11), (122, 40), (122, 66)),
        ((122, 76), (128, 80), (136, 76)),
        // o + đuôi
        ((142, 72), (148, 58), (156, 52)), ((152, 50), (146, 58), (146, 66)), ((146, 74), (152, 79), (159, 79)),
        ((167, 79), (173, 72), (173, 64)), ((173, 56), (167, 50), (161, 50)), ((158, 50), (157, 53), (160, 54)),
        ((168, 56), (180, 52), (192, 46)),
    ]
}

/// Nét "hello" tự vẽ ra bằng Core Animation (strokeEnd = trim của Shape): chạy trong render server ở
/// tần số màn hình (tới 120 Hz), không tốn main thread; vẽ xong là lớp tĩnh, CPU về 0.
struct HelloStroke: NSViewRepresentable {
    var colors: [NSColor]
    var lineWidth: CGFloat
    var delay: CFTimeInterval
    var duration: CFTimeInterval

    func makeNSView(context: Context) -> HelloStrokeView {
        HelloStrokeView(colors: colors, lineWidth: lineWidth, delay: delay, duration: duration)
    }

    func updateNSView(_ view: HelloStrokeView, context: Context) {}
}

final class HelloStrokeView: NSView {
    private let gradient = CAGradientLayer()
    private let stroke = CAShapeLayer()
    private let delay: CFTimeInterval
    private let duration: CFTimeInterval
    private var started = false

    init(colors: [NSColor], lineWidth: CGFloat, delay: CFTimeInterval, duration: CFTimeInterval) {
        self.delay = delay
        self.duration = duration
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.black.cgColor
        stroke.lineWidth = lineWidth
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.strokeEnd = 0
        gradient.mask = stroke
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        stroke.frame = gradient.bounds
        // Path của SwiftUI gốc trên-trái; layer của NSView gốc dưới-trái → lật dọc.
        let rect = bounds.insetBy(dx: stroke.lineWidth / 2, dy: stroke.lineWidth / 2)
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        stroke.path = HelloPath().path(in: rect).cgPath.copy(using: &flip)
        CATransaction.commit()
        if !started, bounds.width > 0, window != nil { start() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !started, bounds.width > 0, window != nil { start() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        gradient.contentsScale = scale
        stroke.contentsScale = scale
    }

    private func start() {
        started = true
        viewDidChangeBackingProperties()
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.beginTime = CACurrentMediaTime() + delay
        anim.duration = duration
        // Bút đi chậm lúc đặt xuống, nhanh ở giữa, chậm dần ở đuôi chữ o.
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.22, 1.0)
        anim.fillMode = .backwards
        anim.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        stroke.strokeEnd = 1
        stroke.add(anim, forKey: "draw")
    }
}

/// Thẻ chào khi mở app: notch giãn ra, "hello" tự viết, rồi lời chào và nút Bắt đầu.
struct WelcomeCard: View {
    let notchHeight: CGFloat
    let onStart: () -> Void

    /// Không dùng macro @State.
    private var shown = State(initialValue: false)

    static let width: CGFloat = 320
    static let bodyHeight: CGFloat = 150
    /// Thời điểm (giây sau khi notch bắt đầu giãn) bút đặt xuống và độ dài nét.
    static let penDelay: CFTimeInterval = 0.4
    static let penDuration: CFTimeInterval = 1.9

    init(notchHeight: CGFloat, onStart: @escaping () -> Void) {
        self.notchHeight = notchHeight
        self.onStart = onStart
    }

    private var colors: [NSColor] {
        switch Theme.current {
        case .cassette:
            return [NSColor(CassettePalette.band), NSColor(CassettePalette.note), NSColor(CassettePalette.band)]
        case .vangogh:
            return [NSColor(VG.muted), NSColor(VG.yellow), NSColor(VG.cream)]
        default:
            return [NSColor(red: 0.35, green: 0.66, blue: 1.0, alpha: 1),
                    NSColor(red: 0.65, green: 0.49, blue: 1.0, alpha: 1),
                    NSColor(red: 1.0, green: 0.48, blue: 0.71, alpha: 1)]
        }
    }

    private var subtitleColor: Color {
        Theme.isCassette ? CassettePalette.label.opacity(0.7) : Theme.isVanGogh ? VG.cream.opacity(0.8) : .white.opacity(0.55)
    }

    private var buttonFill: Color {
        Theme.isCassette ? CassettePalette.key : Theme.isVanGogh ? VG.yellow : Theme.isPixel ? PixelPalette.border : .white
    }

    private var buttonInk: Color {
        Theme.isCassette ? CassettePalette.ink : Theme.isVanGogh ? VG.ink : .black
    }

    var body: some View {
        let on = shown.wrappedValue
        VStack(spacing: 0) {
            HelloStroke(colors: colors, lineWidth: Theme.isPixel ? 6 : 5.2,
                        delay: Self.penDelay, duration: Self.penDuration)
                .frame(width: 168, height: 73)
                .padding(.top, 6)
            Text(L("Chào mừng tới Roost", "Welcome to Roost"))
                .font(Theme.isCassette ? .hand(14) : .ui(12, weight: .medium))
                .foregroundStyle(subtitleColor)
                .padding(.top, 4)
                .opacity(on ? 1 : 0)
                .offset(y: on ? 0 : 6)
                .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(Self.penDelay + Self.penDuration * 0.72),
                           value: on)
            Button(action: onStart) {
                Text(L("Bắt đầu", "Get Started"))
                    .font(Theme.isCassette ? .hand(14) : .ui(12, weight: .semibold))
                    .foregroundStyle(buttonInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(ThemedBackground(fill: buttonFill))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.85)
            .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(Self.penDelay + Self.penDuration * 0.85),
                       value: on)
        }
        .padding(.top, notchHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if Theme.isVanGogh { VGPanelBackground().overlay(VG.night.opacity(0.6)) }
        }
        .clipped()
        .onAppear { shown.wrappedValue = true }
    }
}
