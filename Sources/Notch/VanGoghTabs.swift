import AVFoundation
import AppKit
import CoreImage
import CoreVideo
import Metal
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Khay: tờ canvas, file mới hiện như đang được quét sơn lên

struct VGTrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool
    private var menu = State<TrayMenuTarget?>(initialValue: nil)

    init(tray: TrayStore, targeted: Bool) {
        self.tray = tray
        self.targeted = targeted
    }

    var body: some View {
        HStack(spacing: 16) {
            if !tray.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    TrayFilterBar(tray: tray)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(tray.visibleFiles, id: \.self) { url in
                                VGTile(url: url, tray: tray, selected: tray.selection.contains(url),
                                       remove: { tray.remove(url) },
                                       onMenu: { menu.wrappedValue = .init(url: url, point: $0) })
                                    .modifier(VGPaintIn(url: url, tray: tray))
                                    .modifier(TrayRemovalEffect(tray: tray, url: url))
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxHeight: .infinity)
                    }
                }
                .background(Color.black.opacity(0.001).onTapGesture { tray.selection = [] })
            }
            VGDropZone(targeted: targeted, wide: tray.files.isEmpty)
                .frame(width: tray.files.isEmpty ? nil : 150)
                .trayDropMenu(tray: tray) { menu.wrappedValue = .init(url: nil, point: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .onAppear { tray.prune() }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .trayMenu(menu.binding, tray: tray)
    }
}

/// File mới vào khay (thả, chụp màn hình, chân dung…): lần đầu tile hiện ra thì được "vẽ" lên.
/// Thêm lúc notch đang đóng thì để dành tới khi mở khay.
struct VGPaintIn: ViewModifier {
    private var progress: State<CGFloat>
    private let url: URL
    private let tray: TrayStore

    init(url: URL, tray: TrayStore) {
        self.url = url
        self.tray = tray
        progress = State(initialValue: tray.fresh.contains(url) ? 0 : 1)
    }

    func body(content: Content) -> some View {
        content
            .modifier(BrushReveal(progress: progress.wrappedValue))
            .onAppear {
                guard tray.takeFresh(url) else { return }
                progress.wrappedValue = 0
                withAnimation(.timingCurve(0.3, 0.1, 0.35, 1, duration: 0.75)) { progress.wrappedValue = 1 }
            }
    }
}

/// Bốn vệt cọ chéo lần lượt quét qua tile (mặt nạ), mép lởm chởm như lông cọ, kèm vệt bóng sơn ướt.
struct BrushReveal: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // Không rẽ nhánh theo progress: đổi cấu trúc view sẽ dựng lại tile (và NSView kéo thả bên trong).
    func body(content: Content) -> some View {
        content
            .mask(BrushStrokesMask(progress: progress))
            .overlay(
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(Double(sin(.pi * min(progress, 1))) * 0.8)
                    .mask(BrushStrokesMask(progress: progress))
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            )
    }
}

private struct BrushStrokesMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        let angle = -0.42 // khoảng -24°: nét quét chéo lên
        let span = hypot(r.width, r.height) + 24
        let n = 4
        let band = span / CGFloat(n)
        var all = Path()
        for k in 0..<n {
            // Mỗi vệt bắt đầu muộn hơn vệt trước một chút, chạy hết trong khoảng 46% thời gian.
            let p = min(max((progress - CGFloat(k) * 0.18) / 0.46, 0), 1)
            guard p > 0 else { continue }
            var rng = SeededRNG(UInt64(17 + k * 13))
            let y0 = -span / 2 + CGFloat(k) * band - band * 0.2
            let y1 = y0 + band * 1.4
            let x0 = -span / 2
            let x1 = x0 + span * p
            var s = Path()
            s.move(to: CGPoint(x: x0, y: y0))
            var x = x0
            while x < x1 {
                x = min(x + 6, x1)
                s.addLine(to: CGPoint(x: x, y: y0 + CGFloat(rng.range(-3, 3))))
            }
            // Đầu cọ: các sợi lông so le.
            let teeth = 7
            for t in 0...teeth {
                let y = y0 + (y1 - y0) * CGFloat(t) / CGFloat(teeth)
                s.addLine(to: CGPoint(x: x1 + (t % 2 == 0 ? CGFloat(rng.range(2, 7)) : -CGFloat(rng.range(1, 5))), y: y))
            }
            x = x1
            while x > x0 {
                x = max(x - 6, x0)
                s.addLine(to: CGPoint(x: x, y: y1 + CGFloat(rng.range(-3, 3))))
            }
            s.closeSubpath()
            all.addPath(s)
        }
        let t = CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: angle)
        return all.applying(t)
    }
}

/// Gỡ file: kéo giãn sang ngang như sơn bị quệt, nhoè, để lại vệt rồi tan.
struct PaintSmear: ViewModifier, Animatable {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .overlay(SmearStreaks().opacity(Double(min(1, amount * 2.2))).allowsHitTesting(false))
            .blur(radius: 5 * amount)
            .scaleEffect(x: 1 + 0.9 * amount, y: 1 - 0.14 * amount, anchor: .leading)
            .offset(x: 10 * amount)
            .opacity(Double(1 - amount * amount))
    }
}

/// Các vệt quệt ngang (vàng, kem, xanh) phủ lên tile lúc bị gỡ.
private struct SmearStreaks: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(23)
            let colors = [VG.yellow, VG.cream, VG.cobalt, VG.yellow2]
            for i in 0..<14 {
                let y = rng.range(4, Double(size.height) - 4)
                let x = rng.range(-10, Double(size.width) * 0.3)
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addQuadCurve(to: CGPoint(x: x + rng.range(Double(size.width) * 0.6, Double(size.width) * 1.1), y: y + rng.range(-3, 3)),
                               control: CGPoint(x: x + Double(size.width) * 0.4, y: y + rng.range(-5, 5)))
                ctx.stroke(p, with: .color(colors[i % colors.count].opacity(0.7)),
                           style: StrokeStyle(lineWidth: rng.range(3, 6), lineCap: .round))
            }
        }
    }
}

private struct VGTile: View {
    let url: URL
    @ObservedObject var tray: TrayStore
    let selected: Bool
    let remove: () -> Void
    let onMenu: (CGPoint) -> Void
    private var hover = State(initialValue: false)

    init(url: URL, tray: TrayStore, selected: Bool, remove: @escaping () -> Void, onMenu: @escaping (CGPoint) -> Void) {
        self.url = url
        self.tray = tray
        self.selected = selected
        self.remove = remove
        self.onMenu = onMenu
    }

    var body: some View {
        VStack(spacing: 7) {
            if FileThumbnails.isVisual(url) {
                ThumbnailImage(url: url, size: CGSize(width: 70, height: 54)) { VGCanvasDoc(url: url) }
                    .frame(width: 70, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(VG.yellow))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(VG.ink, lineWidth: 1.6))
            } else {
                VGCanvasDoc(url: url)
            }
            Text(url.lastPathComponent.precomposedStringWithCanonicalMapping)
                .font(.ui(11))
                .foregroundStyle(VG.cream)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 78)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 12).fill(VG.navy.opacity(hover.wrappedValue ? 0.95 : 0.82)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VG.cream.opacity(0.3), lineWidth: 1.2))
        .background(TraySelectionMark(selected: selected))
        .overlay(TrayItemInteraction(url: url, tray: tray))
        .overlay(alignment: .topTrailing) {
            if hover.wrappedValue {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(VG.ink, VG.yellow)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .fileMenu(url: url, remove: remove, quickLook: { TrayQuickLook.shared.show(tray.targets(for: url)) },
                  onThemed: onMenu)
    }
}

/// Tờ canvas gấp góc + nhãn loại file tô màu sơn.
private struct VGCanvasDoc: View {
    let url: URL

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CanvasSheet().fill(VG.paper)
            BrushDaubs(color: Color(red: 0.75, green: 0.68, blue: 0.52), seed: UInt64(abs(url.lastPathComponent.hashValue) % 997), density: 0.6)
                .clipShape(CanvasSheet())
            CanvasSheet().stroke(VG.ink, lineWidth: 1.6)
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .serif))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3).fill(fileTint(url)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(VG.ink, lineWidth: 1.2))
                .offset(x: -6, y: -9)
        }
        .frame(width: 40, height: 54)
    }

    private var label: String {
        if url.hasDirectoryPath { return "DIR" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }
}

private struct CanvasSheet: Shape {
    func path(in r: CGRect) -> Path {
        let fold: CGFloat = 11
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        return p
    }
}

/// Ô thả: viền nét cọ vàng đứt đoạn. Khay trống (rộng) có tranh giỏ táo vẽ nét cọ.
private struct VGDropZone: View {
    let targeted: Bool
    let wide: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(VG.navy.opacity(targeted ? 0.85 : 0.6))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(VG.yellow.opacity(targeted ? 1 : 0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [9, 7])))
            .overlay { wide ? AnyView(emptyState) : AnyView(compact) }
            .scaleEffect(targeted ? 1.03 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: targeted)
    }

    private var compact: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(VG.yellow)
            Text(L("Thả vào khay", "Drop here"))
                .font(.ui(12, weight: .bold))
                .foregroundStyle(VG.cream)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        HStack(spacing: 22) {
            VGAppleBasket()
                .frame(width: 104, height: 82)
                .rotationEffect(.degrees(targeted ? -8 : 0), anchor: .bottom)
                .offset(y: targeted ? -3 : 0)
            VStack(alignment: .leading, spacing: 6) {
                Text(targeted ? L("Thả vào giỏ", "Drop it in the basket")
                              : L("Kéo file lên notch để cất tạm", "Drag files onto the notch to keep them here"))
                    .font(.ui(15, weight: .semibold))
                    .foregroundStyle(VG.cream)
                Text(L("Kéo ra để thả vào bất cứ đâu. Chuột phải để AirDrop hoặc chia sẻ.",
                       "Drag out to drop anywhere. Right-click to AirDrop or share."))
                    .font(.ui(12).italic())
                    .foregroundStyle(VG.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 300, alignment: .leading)
        }
        .padding(.horizontal, 24)
    }
}

/// "Giỏ táo" vẽ bằng nét cọ (tĩnh, vẽ một lần).
struct VGAppleBasket: View {
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 104, sy = size.height / 82
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            func dab(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: CGFloat, ctrl: CGPoint? = nil) {
                var p = Path(); p.move(to: a)
                if let ctrl { p.addQuadCurve(to: b, control: ctrl) } else { p.addLine(to: b) }
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w * sx, lineCap: .round))
            }
            let ink = VG.ink, brown = Color(red: 0.42, green: 0.27, blue: 0.13)
            let ochre = Color(red: 0.71, green: 0.51, blue: 0.18), light = Color(red: 0.85, green: 0.65, blue: 0.29)

            // Quai giỏ
            dab(pt(16, 40), pt(88, 40), brown, 5, ctrl: pt(52, -6))
            dab(pt(18, 38), pt(86, 38), light.opacity(0.8), 1.8, ctrl: pt(52, -4))

            // Táo (sau vành giỏ)
            let apples: [(CGFloat, CGFloat, CGFloat, Color, Color)] = [
                (32, 36, 12, Color(red: 0.62, green: 0.72, blue: 0.25), Color(red: 0.86, green: 0.9, blue: 0.45)),
                (52, 31, 13, Color(red: 0.85, green: 0.34, blue: 0.17), Color(red: 0.98, green: 0.62, blue: 0.3)),
                (72, 36, 12, VG.yellow, Color(red: 1, green: 0.9, blue: 0.55)),
                (43, 40, 10, Color(red: 0.93, green: 0.5, blue: 0.16), VG.yellow),
            ]
            for (x, y, r, base, hi) in apples {
                let c = pt(x, y)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * sx, y: c.y - r * sy, width: 2 * r * sx, height: 2 * r * sy)), with: .color(base))
                for k in 0..<5 {
                    let a = Double(k) * 1.25 + Double(x) * 0.1
                    let p1 = CGPoint(x: c.x + cos(a) * r * 0.55 * sx, y: c.y + sin(a) * r * 0.55 * sy)
                    let p2 = CGPoint(x: c.x + cos(a + 0.9) * r * 0.75 * sx, y: c.y + sin(a + 0.9) * r * 0.75 * sy)
                    dab(p1, p2, k % 2 == 0 ? hi.opacity(0.8) : base.opacity(0.6), 2.4, ctrl: c)
                }
                dab(CGPoint(x: c.x - r * 0.35 * sx, y: c.y - r * 0.4 * sy), CGPoint(x: c.x - r * 0.05 * sx, y: c.y - r * 0.55 * sy), .white.opacity(0.7), 2)
                dab(CGPoint(x: c.x, y: c.y - r * sy), CGPoint(x: c.x + 2 * sx, y: c.y - (r + 4) * sy), brown, 1.8)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r * sx, y: c.y - r * sy, width: 2 * r * sx, height: 2 * r * sy)),
                           with: .color(ink.opacity(0.7)), lineWidth: 1.1)
            }

            // Thân giỏ
            var body = Path()
            body.move(to: pt(8, 44)); body.addLine(to: pt(96, 44)); body.addLine(to: pt(84, 80)); body.addLine(to: pt(20, 80)); body.closeSubpath()
            ctx.fill(body, with: .color(ochre))
            ctx.drawLayer { l in
                l.clip(to: body)
                for row in 0..<6 {
                    let y = 48 + CGFloat(row) * 6
                    for col in 0..<9 {
                        let x = 6 + CGFloat(col) * 11 + (row % 2 == 0 ? 0 : 5.5)
                        var p = Path()
                        p.move(to: pt(x, y)); p.addQuadCurve(to: pt(x + 9, y + 0.5), control: pt(x + 4.5, y + 3))
                        l.stroke(p, with: .color((row + col) % 2 == 0 ? light : brown.opacity(0.85)),
                                 style: StrokeStyle(lineWidth: 2.6 * sx, lineCap: .round))
                    }
                }
                for x in stride(from: CGFloat(16), through: 88, by: 12) {
                    var p = Path(); p.move(to: pt(x, 44)); p.addLine(to: pt(x + (52 - x) * 0.14, 80))
                    l.stroke(p, with: .color(brown.opacity(0.5)), lineWidth: 1.2 * sx)
                }
            }
            ctx.stroke(body, with: .color(ink.opacity(0.8)), lineWidth: 1.4)
            // Vành giỏ
            dab(pt(6, 44), pt(98, 44), brown, 6, ctrl: pt(52, 49))
            dab(pt(8, 42.5), pt(96, 42.5), light, 2, ctrl: pt(52, 47.5))
            // Bóng dưới giỏ
            dab(pt(18, 81), pt(86, 81), ink.opacity(0.35), 3)
        }
    }
}

// MARK: - Gương: "chân dung tự hoạ"

struct VGMirrorView: View {
    @ObservedObject var camera: CameraMirror
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var tray: TrayStore
    @ObservedObject var edge = EdgeLight.shared
    private var flash = State(initialValue: false)

    init(camera: CameraMirror, calendar: CalendarStore, tray: TrayStore) {
        self.camera = camera
        self.calendar = calendar
        self.tray = tray
    }

    var body: some View {
        HStack(spacing: 16) {
            frame.frame(width: 300)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Sẵn sàng họp?", "Ready for the call?"))
                    .font(.ui(16, weight: .bold))
                    .foregroundStyle(VG.cream)
                meeting
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    chip(L("Nét cọ", "Brushwork"), symbol: "paintbrush.pointed.fill", on: camera.painterly) {
                        camera.painterly.toggle()
                    }
                    .help(L("Vẽ lại hình camera bằng nét cọ kiểu Van Gogh", "Repaint the camera image with Van Gogh style brushwork"))
                    if camera.painterly && camera.access == .granted {
                        Button(action: capture) {
                            HStack(spacing: 4) {
                                Image(systemName: "camera.aperture").font(.system(size: 11, weight: .semibold))
                                Text(L("Chụp chân dung", "Paint my portrait"))
                            }
                                .font(.ui(11.5, weight: .semibold))
                                .foregroundStyle(VG.ink)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(VG.yellow))
                                .overlay(BrushDaubs(color: VG.yellow2, seed: 4).clipShape(Capsule()))
                                .overlay(Capsule().stroke(VG.ink, lineWidth: 1.6))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("Lưu bức chân dung vào khay và thư mục Ảnh › Roost", "Save the portrait to the tray and Pictures › Roost"))
                    }
                }
                HStack(spacing: 6) {
                    chip(camera.mirrored ? L("Lật: gương", "Flip: mirror") : L("Lật: thật", "Flip: true view"),
                         symbol: "arrow.left.and.right", on: false) { camera.mirrored.toggle() }
                    chip(edge.level.title, symbol: edge.isOn ? "lightbulb.fill" : "lightbulb", on: edge.isOn) { edge.cycle() }
                        .help(L("Viền sáng quanh màn hình để rọi mặt khi gọi video · bấm để đổi mức / tắt", "A glowing screen border that lights your face on calls · click to change level / turn off"))
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VGScrim(strength: 0.5).padding(-20))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    /// Khung tranh quét sơn vàng quanh camera.
    @ViewBuilder private var frame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(VG.yellow)
            BrushDaubs(color: VG.yellow2, seed: 21, density: 1.3).clipShape(RoundedRectangle(cornerRadius: 14))
            RoundedRectangle(cornerRadius: 14).stroke(VG.ink, lineWidth: 2)
            preview
                .padding(7)
            if flash.wrappedValue {
                RoundedRectangle(cornerRadius: 10).fill(.white).padding(7).transition(.opacity)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch camera.access {
        case .granted:
            Group {
                if camera.painterly {
                    PainterlyPreview(camera: camera, cornerRadius: 10)
                } else {
                    CameraPreview(session: camera.session, cornerRadius: 10, mirrored: camera.mirrored)
                }
            }
            .overlay { if camera.frameState == .live { MirrorGuideOverlay(hint: camera.guide) } }
            .overlay { if camera.frameState != .live { noFrames } }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VG.ink, lineWidth: 2))
        case .notDetermined:
            placeholder(icon: "camera.fill", text: L("Bật camera để soi gương", "Turn on the camera"), action: camera.requestAccess)
        case .denied:
            placeholder(icon: "camera.badge.ellipsis", text: L("Mở Cài đặt để cấp quyền camera", "Open Settings to allow camera access"),
                        action: camera.openPrivacySettings)
        }
    }

    /// Camera đã được phép nhưng chưa ra hình: báo rõ trong khung thay vì để một ô tối trơn.
    private var noFrames: some View {
        let starting = camera.frameState == .starting
        return RoundedRectangle(cornerRadius: 10).fill(VG.navy)
            .overlay(VStack(spacing: 6) {
                Image(systemName: starting ? "camera" : "video.slash").font(.system(size: 22))
                    .foregroundStyle(VG.yellow)
                Text(starting ? L("Đang bật camera…", "Starting the camera…") : L("Camera chưa có hình", "No picture from the camera"))
                    .font(.ui(13, weight: .semibold))
                    .foregroundStyle(VG.cream)
                if !starting {
                    Text(L("Mở nắp máy, hoặc tắt app khác đang dùng camera", "Open the lid, or quit other apps using the camera"))
                        .font(.ui(11).italic())
                        .foregroundStyle(VG.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            })
            .allowsHitTesting(false)
    }

    private func placeholder(icon: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 10).fill(VG.navy)
                .overlay(VStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 22))
                    Text(text).font(.ui(12, weight: .semibold)).multilineTextAlignment(.center)
                }
                .foregroundStyle(VG.cream))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var meeting: some View {
        if let next = calendar.nextEvent {
            HStack(spacing: 8) {
                Capsule().fill(VG.yellow).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(next.title).font(.ui(12.5, weight: .bold)).foregroundStyle(VG.cream).lineLimit(1)
                    Text(Self.timeText(next)).font(.ui(11)).foregroundStyle(VG.muted).lineLimit(1)
                }
                if let link = next.meeting {
                    Spacer(minLength: 4)
                    JoinButton(meeting: link, prominent: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(VG.navy.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VG.cream.opacity(0.35), lineWidth: 1))
        } else {
            Text(calendar.access == .granted ? L("Hôm nay không còn cuộc họp nào", "No more meetings today") : L("Soi lại trước khi lên hình", "Check yourself before going on camera"))
                .font(.ui(12).italic())
                .foregroundStyle(VG.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title)
            }
                .font(.ui(11.5, weight: .semibold))
                .foregroundStyle(on ? VG.ink : VG.cream)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(on ? VG.yellow : VG.navy.opacity(0.9)))
                .overlay(Capsule().stroke(on ? VG.ink : VG.cream.opacity(0.6), lineWidth: 1.4))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func capture() {
        withAnimation(.easeOut(duration: 0.08)) { flash.wrappedValue = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeIn(duration: 0.3)) { flash.wrappedValue = false }
        }
        Haptics.tap(.levelChange)
        camera.painter.capture(mirrored: camera.mirrored) { url in
            guard let url else { return }
            tray.add(url)
        }
    }

    private static func timeText(_ item: CalendarStore.Item) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let minutes = Int(item.start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return L("Đang diễn ra · đến \(f.string(from: item.end))", "Now · until \(f.string(from: item.end))") }
        if minutes < 60 { return L("Sau \(minutes) phút · \(f.string(from: item.start))", "In \(minutes) min · \(f.string(from: item.start))") }
        return "\(f.string(from: item.start)) – \(f.string(from: item.end))"
    }
}

/// Vẽ lại khung hình camera trên GPU (nét cọ Van Gogh, ô pixel 8-bit), tối đa 24 hình/giây.
/// Chỉ chạy khi tab gương đang mở và bật bộ lọc của giao diện.
final class Painterly: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = false
    private var _onFrame: ((CVPixelBuffer) -> Void)?
    private var _filter: (CIImage) -> CIImage = { OilPaint.paint($0) }
    private var _still: ((CGImage?) -> Void)?

    /// Bộ lọc áp lên từng khung hình (đổi theo giao diện).
    var filter: (CIImage) -> CIImage {
        get { lock.withLock { _filter } }
        set { lock.withLock { _filter = newValue } }
    }

    /// Lấy một khung hình gốc kế tiếp (không lọc), trả về trên main. Dùng cho ảnh Polaroid.
    func grabStill(_ done: @escaping (CGImage?) -> Void) {
        lock.withLock { _still = done }
    }

    func cancelStill() -> ((CGImage?) -> Void)? {
        lock.withLock { defer { _still = nil }; return _still }
    }
    private var last: CFTimeInterval = 0
    private var credit: Double = 1
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var lastPainted: CIImage?

    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue; if !newValue { lastPainted = nil } } }
    }

    /// Gọi trên main với bộ đệm đã vẽ (IOSurface) để hiện lên layer.
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Chạy trên queue phân tích của camera.
    func consume(_ pixels: CVPixelBuffer) {
        if let still = cancelStill() {
            let cg = OilPaint.context.createCGImage(CIImage(cvPixelBuffer: pixels), from: CIImage(cvPixelBuffer: pixels).extent)
            DispatchQueue.main.async { still(cg) }
        }
        guard enabled, let deliver = onFrame else { return }
        // Camera 30 hình/giây → nhận 4/5 khung, giữ khoảng 24 hình/giây.
        let now = CACurrentMediaTime()
        credit = min(credit + (now - last) * 24, 1.5)
        last = now
        guard credit >= 1 else { return }
        credit -= 1
        let painted = filter(CIImage(cvPixelBuffer: pixels))
        let size = painted.extent.size
        guard let out = buffer(size) else { return }
        OilPaint.context.render(painted, to: out)
        lock.withLock { lastPainted = painted }
        DispatchQueue.main.async { deliver(out) }
    }

    private func buffer(_ size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    /// Lưu khung hình đã vẽ gần nhất thành PNG trong ~/Pictures/Roost.
    /// `upscale` > 1: phóng to giữ ô vuông sắc nét (ảnh pixel nhỏ).
    @MainActor func capture(mirrored: Bool, name: String = L("Chân dung", "Portrait"), upscale: CGFloat = 1,
                            done: @escaping @MainActor (URL?) -> Void) {
        guard var image = lock.withLock({ lastPainted }) else { done(nil); return }
        if mirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
        }
        if upscale > 1 {
            image = image.samplingNearest().transformed(by: CGAffineTransform(scaleX: upscale, y: upscale))
            let e = image.extent.integral
            image = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        }
        Self.save(image, name: name, done: done)
    }

    /// Ghi ảnh thành PNG trong ~/Pictures/Roost (nền), báo URL trên main.
    @MainActor static func save(_ shot: CIImage, name: String, done: @escaping @MainActor (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Roost", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = dir.appendingPathComponent("\(name) \(f.string(from: Date())).png")
            let ok: Bool
            if let cs = CGColorSpace(name: CGColorSpace.sRGB) {
                ok = (try? OilPaint.context.writePNGRepresentation(of: shot, to: url, format: .RGBA8, colorSpace: cs)) != nil
            } else {
                ok = false
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok ? url : nil) } }
        }
    }
}

struct PainterlyPreview: NSViewRepresentable {
    let camera: CameraMirror
    let cornerRadius: CGFloat
    var pixelated = false

    func makeNSView(context: Context) -> PainterlyView {
        let view = PainterlyView(cornerRadius: cornerRadius)
        camera.painter.onFrame = { [weak view] pb in
            MainActor.assumeIsolated { view?.show(pb) }
        }
        return view
    }

    func updateNSView(_ view: PainterlyView, context: Context) {
        view.mirrored = camera.mirrored
        view.pixelated = pixelated
    }

    static func dismantleNSView(_ view: PainterlyView, coordinator: ()) {
        view.clear()
    }
}

final class PainterlyView: NSView {
    private let image = CALayer()
    /// Giữ vài bộ đệm gần nhất để pool không ghi đè lúc layer còn đang hiện.
    private var recent: [CVPixelBuffer] = []
    var mirrored = true {
        didSet { if mirrored != oldValue { needsLayout = true } }
    }
    /// Ảnh pixel nhỏ: phóng to giữ ô vuông sắc (không làm mờ).
    var pixelated = false {
        didSet { image.magnificationFilter = pixelated ? .nearest : .linear }
    }

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.1, blue: 0.28, alpha: 1).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        image.contentsGravity = .resizeAspectFill
        layer?.addSublayer(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pb: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        recent.append(pb)
        if recent.count > 3 { recent.removeFirst() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = surface
        CATransaction.commit()
    }

    func clear() {
        recent = []
        image.contents = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        image.bounds = bounds
        image.position = CGPoint(x: bounds.midX, y: bounds.midY)
        image.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }
}

// MARK: - Claude: lá thư viết tay trên giấy kem

struct VGLetterCard: View {
    let request: PermissionRequest
    let pending: Int
    let decide: (PermissionDecision) -> Void

    private var waiting: Bool { request.state.isWaiting }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LetterPaper()
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("Gửi bạn,", "Dear friend,"))
                        .font(.custom("Snell Roundhand", size: 19).weight(.bold))
                        .foregroundStyle(VG.paperInk)
                        .fixedSize()
                    OriginRow(request: request, paper: true, size: 10.5)
                    Spacer(minLength: 4)
                    CountdownBadge(request: request, paper: true)
                }
                .lineLimit(1)
                HStack(spacing: 6) {
                    Text(request.kindTitle)
                        .font(.ui(12.5, weight: .semibold))
                        .foregroundStyle(VG.paperInk)
                    if request.kind == .tool {
                        Text(request.tool)
                            .font(.ui(11, weight: .bold))
                            .foregroundStyle(VG.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(VG.yellow))
                            .overlay(Capsule().stroke(VG.ink, lineWidth: 1))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.summary.isEmpty ? " " : request.summary)
                        .font(request.kind == .plan ? .ui(12, weight: .semibold) : .system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VG.paperInk)
                        .lineLimit(request.detail == nil ? 2 : 1)
                        .truncationMode(.middle)
                        .help(request.summary)
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.ui(10.5).italic())
                            .foregroundStyle(VG.paperInk.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.91, green: 0.85, blue: 0.7)))
                .overlay(alignment: .leading) { Capsule().fill(VG.yellow2).frame(width: 3).padding(.vertical, 4) }
                .opacity(waiting ? 1 : 0.55)
                ScopeLine(request: request, paper: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(L("Thân, Claude", "Yours, Claude"))
                        .font(.custom("Snell Roundhand", size: 16).weight(.bold))
                        .foregroundStyle(VG.paperInk.opacity(0.85))
                        .fixedSize()
                    if let host = request.host {
                        Button { PermissionCenter.active?.openHost(request) } label: {
                            Text(L("mở \(host.name)", "open \(host.name)"))
                                .font(.ui(11))
                                .underline()
                                .foregroundStyle(VG.paperInk.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help(L("Đưa app đang chạy phiên này lên trước", "Bring the app running this session to the front"))
                    }
                    Spacer()
                    if waiting {
                        Button(request.kind == .plan ? L("Chưa duyệt", "Keep planning") : L("Từ chối", "Deny")) { decide(.deny) }
                            .buttonStyle(VGLetterButton(kind: .plain))
                        if request.canAlwaysAllow {
                            Button(request.alwaysTitle) { decide(.allowAlways) }
                                .buttonStyle(VGLetterButton(kind: .outline))
                                .help(request.alwaysHelp)
                        }
                        Button(request.kind == .plan ? L("Duyệt kế hoạch", "Approve plan") : L("Cho phép", "Allow")) { decide(.allow) }
                            .buttonStyle(VGLetterButton(kind: .main))
                    } else {
                        StateBanner(state: request.state, paper: true)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: waiting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}

/// Giấy thư màu kem, mép hơi ố, vài vệt màu vẽ nhoè ở góc.
private struct LetterPaper: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(VG.paper)
            .overlay(BrushDaubs(color: Color(red: 0.86, green: 0.79, blue: 0.62), seed: 31, density: 0.35)
                .clipShape(RoundedRectangle(cornerRadius: 10)))
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(VG.yellow.opacity(0.35)).frame(width: 46, height: 46).blur(radius: 6).offset(x: 10, y: 12)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VG.ink, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }
}

private struct VGLetterButton: ButtonStyle {
    enum Kind { case main, outline, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12.5, weight: .bold))
            .foregroundStyle(kind == .main ? VG.ink : VG.paperInk)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                switch kind {
                case .main:
                    Capsule().fill(VG.yellow).overlay(BrushDaubs(color: VG.yellow2, seed: 6).clipShape(Capsule()))
                case .outline:
                    Capsule().fill(Color.white.opacity(0.35))
                case .plain:
                    Capsule().fill(Color.clear)
                }
            }
            .overlay(Capsule().stroke(VG.paperInk.opacity(kind == .plain ? 0.45 : 0.9), lineWidth: kind == .main ? 1.8 : 1.3))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
    }
}
