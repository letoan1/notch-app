import AppKit
import CoreImage
import Metal
import SwiftUI

/// Giao diện Van Gogh: nền "Đêm đầy sao", nét cọ vàng, hoạ sĩ chibi. Tranh nền + hoạ sĩ là ảnh tạo bằng AI.
enum VG {
    static let ink = Color(red: 0.043, green: 0.078, blue: 0.2)
    static let cream = Color(red: 0.97, green: 0.906, blue: 0.69)
    static let muted = Color(red: 0.663, green: 0.741, blue: 0.902)
    static let yellow = Color(red: 0.949, green: 0.757, blue: 0.306)
    static let yellow2 = Color(red: 0.851, green: 0.604, blue: 0.169)
    static let navy = Color(red: 0.055, green: 0.102, blue: 0.282)
    static let night = Color(red: 0.039, green: 0.07, blue: 0.21)
    static let paper = Color(red: 0.96, green: 0.92, blue: 0.80)
    static let paperInk = Color(red: 0.23, green: 0.16, blue: 0.1)

    static let cobalt = Color(red: 0.231, green: 0.424, blue: 0.769)

    static let nsYellow = NSColor(red: 0.949, green: 0.757, blue: 0.306, alpha: 1)

    /// Chữ đậm của theme dừng ở semibold: New York đậm hơn mức đó trông thô.
    static func weight(_ w: Font.Weight) -> Font.Weight {
        switch w {
        case .bold, .heavy, .black: return .semibold
        default: return w
        }
    }

    static let panel: NSImage? = Bundle.main.url(forResource: "vangogh-panel", withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
    static let painter: CGImage? = Bundle.main.url(forResource: "vangogh-painter", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// Bộ sinh số ngẫu nhiên cố định theo seed: vệt cọ không đổi giữa các lần vẽ.
struct SeededRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// Vệt cọ ngắn rải trên một mảng màu (nút, menu, ô chọn).
struct BrushDaubs: View {
    let color: Color
    var seed: UInt64 = 1
    var density: Double = 1

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(seed)
            let n = Int(Double(size.width * size.height) / 70 * density)
            for _ in 0..<max(n, 3) {
                let x = rng.range(2, Double(size.width) - 2), y = rng.range(2, Double(size.height) - 2)
                let dx = rng.range(4, 9)
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addQuadCurve(to: CGPoint(x: x + dx, y: y + rng.range(-1.5, 1.5)),
                               control: CGPoint(x: x + dx / 2, y: y + rng.range(-2, 2)))
                ctx.stroke(p, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: rng.range(2.2, 4.2), lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Quầng tối mềm sau chữ nằm trên vùng xoáy sáng của nền tranh.
struct VGScrim: View {
    var strength: Double = 0.7

    var body: some View {
        Ellipse().fill(RadialGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.09).opacity(strength), .clear],
                                      center: .center, startRadius: 0, endRadius: 120))
            .allowsHitTesting(false)
    }
}

/// Nền notch mở: tranh "Đêm đầy sao", phủ kín khung.
struct VGPanelBackground: View {
    var body: some View {
        if let panel = VG.panel {
            Image(nsImage: panel).resizable().interpolation(.high).scaledToFill()
        } else {
            VG.navy
        }
    }
}

/// Vòng xoáy vàng quanh ngày hôm nay / nút kéo.
struct VGSwirlHalo: View {
    var body: some View {
        ZStack {
            Circle().stroke(VG.muted.opacity(0.9), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [6, 3]))
            Circle().stroke(VG.yellow, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [5, 2.5], dashPhase: 3))
                .padding(3.5)
            Circle().fill(Color(red: 1, green: 0.94, blue: 0.69)).padding(6.5)
        }
    }
}

// MARK: - Hình vẽ sẵn (cache)

@MainActor
enum VGArt {
    private static var strokes: [String: CGImage] = [:]
    private static var flowers: [Int: NSImage] = [:]

    /// Dải nét cọ ngang (thanh tiến độ). `dark` = rãnh xanh thẫm, không thì vệt sơn vàng.
    static func stroke(dark: Bool) -> CGImage? {
        let key = dark ? "dark" : "light"
        if let hit = strokes[key] { return hit }
        let w = 720, h = 30
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let palette: [NSColor] = dark
            ? [NSColor(red: 0.06, green: 0.1, blue: 0.27, alpha: 1), NSColor(red: 0.1, green: 0.16, blue: 0.38, alpha: 1),
               NSColor(red: 0.04, green: 0.07, blue: 0.2, alpha: 1)]
            : [VG.nsYellow, NSColor(red: 0.97, green: 0.85, blue: 0.42, alpha: 1),
               NSColor(red: 0.85, green: 0.6, blue: 0.17, alpha: 1), NSColor(red: 1, green: 0.94, blue: 0.7, alpha: 1)]
        var rng = SeededRNG(dark ? 7 : 11)
        ctx.setLineCap(.round)
        for _ in 0..<520 {
            let x = rng.range(4, Double(w) - 4)
            // Hai đầu thuôn: càng gần mép càng ít sơn.
            let edge = min(x, Double(w) - x) / 40
            let half = Double(h) / 2 * min(1, 0.45 + edge * 0.55)
            let y = Double(h) / 2 + rng.range(-half + 4, half - 4)
            let len = rng.range(14, 34)
            ctx.setStrokeColor(palette[Int(rng.next() * Double(palette.count)) % palette.count].withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(rng.range(5, 9))
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addQuadCurve(to: CGPoint(x: x + len, y: y + rng.range(-2, 2)), control: CGPoint(x: x + len / 2, y: y + rng.range(-3, 3)))
            ctx.strokePath()
        }
        let img = ctx.makeImage()
        strokes[key] = img
        return img
    }

    private static var vStrokes: [Int: CGImage] = [:]

    /// Vệt cọ vàng dựng đứng cho sóng nhạc (mỗi cột một vệt hơi khác).
    static func verticalStroke(_ index: Int) -> CGImage? {
        let key = index % 4
        if let hit = vStrokes[key] { return hit }
        let w = 12, h = 40
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let palette: [NSColor] = [VG.nsYellow, NSColor(red: 0.97, green: 0.85, blue: 0.42, alpha: 1),
                                  NSColor(red: 0.85, green: 0.6, blue: 0.17, alpha: 1), NSColor(red: 1, green: 0.94, blue: 0.7, alpha: 1)]
        var rng = SeededRNG(UInt64(31 + key * 7))
        ctx.setLineCap(.round)
        for _ in 0..<26 {
            let x = rng.range(3, Double(w) - 3)
            let y = rng.range(2, Double(h) - 12)
            ctx.setStrokeColor(palette[Int(rng.next() * 4) % 4].cgColor)
            ctx.setLineWidth(rng.range(3, 5))
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + rng.range(-1.5, 1.5), y: y + rng.range(8, 14)))
            ctx.strokePath()
        }
        let img = ctx.makeImage()
        vStrokes[key] = img
        return img
    }

    /// Hoa hướng dương nhỏ dưới ngày có sự kiện (to dần theo số sự kiện).
    static func sunflower(_ size: Int) -> NSImage {
        if let hit = flowers[size] { return hit }
        let px = size * 2
        let img = NSImage(size: NSSize(width: size, height: size))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let c = CGFloat(size) / 2
        let petal = CGFloat(size) * 0.3
        for (i, color) in [(0, NSColor(red: 0.85, green: 0.6, blue: 0.17, alpha: 1)), (1, VG.nsYellow)] {
            color.setFill()
            for k in 0..<10 {
                let a = (Double(k) + (i == 0 ? 0.5 : 0)) / 10 * .pi * 2
                let t = NSAffineTransform()
                t.translateX(by: c, yBy: c)
                t.rotate(byRadians: a)
                let p = NSBezierPath(ovalIn: NSRect(x: c * 0.28, y: -petal * 0.22, width: petal * (i == 0 ? 1.05 : 0.95), height: petal * 0.44))
                p.transform(using: t as AffineTransform)
                p.fill()
            }
        }
        NSColor(red: 0.42, green: 0.25, blue: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c - c * 0.36, y: c - c * 0.36, width: c * 0.72, height: c * 0.72)).fill()
        NSColor(red: 0.27, green: 0.15, blue: 0.06, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c - c * 0.16, y: c - c * 0.16, width: c * 0.32, height: c * 0.32)).fill()
        NSGraphicsContext.restoreGraphicsState()
        img.addRepresentation(rep)
        flowers[size] = img
        return img
    }
}

// MARK: - Bộ lọc sơn dầu (Kuwahara, biên dịch lúc chạy) + vân nét cọ

enum OilPaint {
    /// Kuwahara 4 góc, bán kính 4: mảng màu phẳng, viền giữ sắc như nét cọ dày.
    private static let kernel: CIKernel? = {
        let src = """
        kernel vec4 roostKuwahara(sampler s) {
            vec2 d = destCoord();
            vec3 m0 = vec3(0.0); vec3 m1 = vec3(0.0); vec3 m2 = vec3(0.0); vec3 m3 = vec3(0.0);
            vec3 q0 = vec3(0.0); vec3 q1 = vec3(0.0); vec3 q2 = vec3(0.0); vec3 q3 = vec3(0.0);
            for (int j = -4; j <= 0; j++) {
                for (int i = -4; i <= 0; i++) {
                    vec3 c = sample(s, samplerTransform(s, d + vec2(float(i), float(j)))).rgb; m0 += c; q0 += c * c;
                    c = sample(s, samplerTransform(s, d + vec2(float(i + 4), float(j)))).rgb; m1 += c; q1 += c * c;
                    c = sample(s, samplerTransform(s, d + vec2(float(i), float(j + 4)))).rgb; m2 += c; q2 += c * c;
                    c = sample(s, samplerTransform(s, d + vec2(float(i + 4), float(j + 4)))).rgb; m3 += c; q3 += c * c;
                }
            }
            m0 /= 25.0; m1 /= 25.0; m2 /= 25.0; m3 /= 25.0;
            vec3 v0 = abs(q0 / 25.0 - m0 * m0); vec3 v1 = abs(q1 / 25.0 - m1 * m1);
            vec3 v2 = abs(q2 / 25.0 - m2 * m2); vec3 v3 = abs(q3 / 25.0 - m3 * m3);
            float s0 = v0.r + v0.g + v0.b; float s1 = v1.r + v1.g + v1.b;
            float s2 = v2.r + v2.g + v2.b; float s3 = v3.r + v3.g + v3.b;
            vec3 r = m0; float best = s0;
            if (s1 < best) { best = s1; r = m1; }
            if (s2 < best) { best = s2; r = m2; }
            if (s3 < best) { best = s3; r = m3; }
            return vec4(r, 1.0);
        }
        """
        return CIKernel(source: src)
    }()

    /// Vân nét cọ xám trung tính (lát 256×256) để hoà kiểu soft light lên ảnh.
    private static let texture: CIImage? = {
        let n = 256
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.setLineCap(.round)
        var rng = SeededRNG(5)
        for _ in 0..<900 {
            let x = rng.range(-10, Double(n) + 10), y = rng.range(-10, Double(n) + 10)
            // Hướng nét xoáy nhẹ theo vị trí: không đều tăm tắp như vân vải.
            let a = sin(x / 40) * 0.9 + cos(y / 55) * 0.7
            let len = rng.range(6, 16)
            ctx.setStrokeColor(gray: rng.range(0.36, 0.66), alpha: 1)
            ctx.setLineWidth(rng.range(1.6, 3.4))
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + cos(a) * len, y: y + sin(a) * len))
            ctx.strokePath()
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }()

    static func paint(_ input: CIImage, maxWidth: CGFloat = 960, textureStrength: Double = 1) -> CIImage {
        var img = input
        if img.extent.width > maxWidth {
            let s = maxWidth / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let extent = img.extent
        var out: CIImage
        if let kernel {
            out = kernel.apply(extent: extent, roiCallback: { _, r in r.insetBy(dx: -5, dy: -5) },
                               arguments: [img.clampedToExtent()]) ?? img
        } else {
            out = img.applyingFilter("CIMedianFilter")
        }
        out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.08])
        if let texture, textureStrength > 0 {
            let tiled = texture.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()])
                .cropped(to: extent)
            let soft = tiled.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: out])
            out = textureStrength >= 1 ? soft
                : soft.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputTimeKey: 1 - textureStrength])
        }
        return out.cropped(to: extent)
    }

    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "roost.oil"])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// Ảnh bìa thành tranh sơn dầu: một lần mỗi ảnh, chạy nền.
    private static let cache = NSCache<NSImage, NSImage>()

    /// Bản sơn dầu đã vẽ (nếu có), dùng cho ô ảnh nhỏ ở notch thu gọn.
    static func cached(_ image: NSImage) -> NSImage? { cache.object(forKey: image) }

    static func artwork(_ image: NSImage) async -> NSImage? {
        if let hit = cache.object(forKey: image) { return hit }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result: NSImage? = await Task.detached(priority: .utility) {
            guard let out = paintArtwork(cg) else { return nil }
            return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        }.value
        if let result { cache.setObject(result, forKey: image) }
        return result
    }

    /// Ảnh nhỏ (thumbnail YouTube 120–320 px) phóng lên ≥ 560 px trước khi lọc, để nét cọ
    /// không thành khối vuông; sau đó trộn lại 30% ảnh gốc cho mặt người, chữ còn nhận ra được.
    static func paintArtwork(_ cg: CGImage) -> CGImage? {
        var src = CIImage(cgImage: cg)
        let short = min(src.extent.width, src.extent.height)
        let target: CGFloat = 560
        if short < target {
            let scale = target / short
            src = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        } else if short > 720 {
            let scale = 720 / short
            src = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
        let extent = src.extent
        let painted = paint(src, maxWidth: 2000, textureStrength: 0.45)
        let mixed = painted.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: src, kCIInputTimeKey: 0.3])
            .cropped(to: extent)
        return context.createCGImage(mixed, from: extent)
    }
}

// MARK: - Trình phát

/// Ảnh bìa vẽ lại kiểu sơn dầu (ảnh gốc hiện tạm trong lúc lọc).
struct OilArtwork: View {
    let image: NSImage?
    private var painted = State<NSImage?>(initialValue: nil)

    init(image: NSImage?) { self.image = image }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(VG.navy)
            if let shown = painted.wrappedValue ?? image {
                Color.clear.overlay(Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fill))
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(VG.muted)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(VG.ink, lineWidth: 3))
        .animation(.easeOut(duration: 0.35), value: painted.wrappedValue)
        .task(id: image.map(ObjectIdentifier.init)) {
            painted.wrappedValue = nil
            guard let image else { return }
            let out = await OilPaint.artwork(image)
            if !Task.isCancelled { painted.wrappedValue = out }
        }
    }
}

struct VGPlayerView: View {
    @ObservedObject var media: NowPlaying
    let track: Track

    var body: some View {
        HStack(spacing: 18) {
            OilArtwork(image: media.artwork)
                .frame(width: 104, height: 104)
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }
                .help(L("Mở \(track.appName)", "Open \(track.appName)"))
                .overlay(alignment: .bottomTrailing) {
                    SourceBadge(bundleID: track.bundleID, size: 28, open: media.openPlayer).offset(x: 7, y: 7)
                }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.ui(17, weight: .bold))
                        .foregroundStyle(VG.cream)
                    HStack(spacing: 8) {
                        Text(track.artist)
                            .font(.ui(13).italic())
                            .foregroundStyle(VG.muted)
                        if track.isPlaying {
                            EqualizerBars(active: true, color: VG.yellow)
                                .frame(width: 16, height: 13)
                        }
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }
                .background(VGScrim(strength: 0.55).padding(-14))

                // Chừa chỗ cho hoạ sĩ đứng trên vệt sơn.
                ProgressRow(track: track, accent: VG.yellow, seek: media.seek)
                    .padding(.top, 14)

                let modes = media.modes
                HStack(spacing: modes == nil ? 14 : 6) {
                    if let modes { ModeButton(kind: .shuffle, modes: modes, action: media.toggleShuffle) }
                    ControlButton(symbol: "backward.fill", size: 15, action: media.previous)
                    ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 19, action: media.playPause)
                    ControlButton(symbol: "forward.fill", size: 15, action: media.next)
                    if let modes { ModeButton(kind: .repeatMode, modes: modes, action: media.cycleRepeat) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .onAppear { media.refreshModes(force: true) }
    }
}

/// Nút điều khiển kiểu Van Gogh: phát/dừng = vòng vàng có vệt cọ, lùi/tới = viền kem trên nền đêm.
struct VGControlFace: View {
    let symbol: String
    let size: CGFloat
    let hovering: Bool

    var body: some View {
        let main = symbol.hasPrefix("pause") || symbol.hasPrefix("play")
        let d: CGFloat = main ? 42 : 34
        ZStack {
            Circle().fill(main ? VG.yellow : VG.navy.opacity(0.9))
            if main { BrushDaubs(color: VG.yellow2, seed: 9, density: 1.4).clipShape(Circle()) }
            Circle().stroke(main ? VG.ink : VG.cream.opacity(hovering ? 1 : 0.8), lineWidth: main ? 2.4 : 1.8)
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(main ? VG.ink : VG.cream)
        }
        .frame(width: d, height: d)
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Luồng trực tiếp / không biết độ dài: không có vệt để vẽ, chỉ ghi "Trực tiếp" bên một vệt cọ ngắn.
struct VGLiveBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(VG.yellow).frame(width: 18, height: 5)
                .overlay(BrushDaubs(color: VG.yellow2, seed: 3, density: 2).clipShape(Capsule()))
            Text(L("Trực tiếp", "Live"))
                .font(.ui(12, weight: .medium).italic())
                .foregroundStyle(VG.muted)
            Spacer(minLength: 0)
        }
        .frame(height: 14)
    }
}

// MARK: - Thanh tiến độ: vệt sơn vàng + hoạ sĩ đi theo đầu vệt

struct BrushProgressBar: NSViewRepresentable {
    let track: Track
    let override: Double?

    func makeNSView(context: Context) -> BrushProgressView { BrushProgressView() }
    func updateNSView(_ view: BrushProgressView, context: Context) { view.update(track: track, override: override) }
}

/// Cùng cách với LiveProgressView: render server tự kéo dài vệt sơn và dời hoạ sĩ, app chỉ đặt lại
/// animation khi bài / vị trí / trạng thái / kích thước đổi.
final class BrushProgressView: NSView {
    private let rail = CALayer()
    private let clip = CALayer()
    private let paint = CALayer()
    private let rider = CALayer()
    private let riderBody = CALayer()
    private var track: Track?
    private var override: Double?
    private static let riderSize = CGSize(width: 15, height: 23)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rail.contents = VGArt.stroke(dark: true)
        rail.contentsGravity = .resize
        paint.contents = VGArt.stroke(dark: false)
        paint.contentsGravity = .resize
        clip.masksToBounds = true
        clip.anchorPoint = CGPoint(x: 0, y: 0.5)
        clip.addSublayer(paint)
        riderBody.contents = VG.painter
        riderBody.contentsGravity = .resizeAspect
        riderBody.minificationFilter = .trilinear
        rider.addSublayer(riderBody)
        for l in [rail, clip, rider] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(track: Track, override: Double?) {
        let changed = self.track.map { !Self.sameRun($0, track) } ?? true
        let wasDragging = self.override != nil
        self.track = track
        self.override = override
        if changed || override != nil || wasDragging { restart() }
    }

    private static func sameRun(_ a: Track, _ b: Track) -> Bool {
        a.isPlaying == b.isPlaying && a.duration == b.duration && a.title == b.title
            && abs(a.position(at: Date()) - b.position(at: Date())) < 0.25
    }

    override func layout() {
        super.layout()
        restart()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [layer, rail, clip, paint, rider, riderBody] { l?.contentsScale = scale }
    }

    private func restart() {
        guard let track else { return }
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let now = Date()
        let dur = max(track.duration, 0.001)
        let ratio = override ?? min(max(track.position(at: now) / dur, 0), 1)
        // Hướng trục y của lớp con (tuỳ AppKit lật hay không): hoạ sĩ luôn đứng phía trên vệt sơn.
        let yDown = rail.contentsAreFlipped()
        let rs = Self.riderSize
        let riderX = { (r: Double) in min(max(w * r, rs.width / 2 - 4), w - rs.width / 2 + 4) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.frame = bounds
        clip.removeAnimation(forKey: "run")
        rider.removeAnimation(forKey: "run")
        clip.bounds = CGRect(x: 0, y: 0, width: w * ratio, height: h)
        clip.position = CGPoint(x: 0, y: h / 2)
        paint.frame = CGRect(x: 0, y: 0, width: w, height: h)
        rider.bounds = CGRect(origin: .zero, size: rs)
        rider.anchorPoint = CGPoint(x: 0.5, y: yDown ? 1 : 0)
        rider.position = CGPoint(x: riderX(ratio), y: yDown ? h * 0.35 : h * 0.65)
        riderBody.frame = rider.bounds

        let remaining = track.duration - track.position(at: now)
        let playing = override == nil && track.isPlaying && remaining > 0.05
        if playing {
            let begin = CACurrentMediaTime()
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = w * ratio
            grow.toValue = w
            let walk = CABasicAnimation(keyPath: "position.x")
            walk.fromValue = riderX(ratio)
            walk.toValue = riderX(1)
            for (a, l) in [(grow, clip), (walk, rider)] {
                a.beginTime = begin
                a.duration = remaining
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 15)
                l.add(a, forKey: "run")
            }
            // Nhún theo nhịp bước: khung rời, render server chỉ vẽ lại vài lần/giây.
            if riderBody.animation(forKey: "step") == nil {
                riderBody.add(loop("transform.translation.y", [0, yDown ? -1.2 : 1.2], times: [0, 0.5], duration: 0.7), forKey: "step")
                riderBody.add(loop("transform.rotation.z", [0.06, -0.06], times: [0, 0.5], duration: 1.4), forKey: "sway")
            }
        } else {
            riderBody.removeAllAnimations()
        }
        CATransaction.commit()
    }
}

// MARK: - Hàng tab: icon nét cọ + mảng sơn quệt

/// Icon vẽ bằng nét cọ theo đề tài tranh: nốt nhạc, giỏ đan, giá vẽ, hướng dương, nút nguồn.
struct VGIcon: View {
    enum Kind { case music, basket, easel, sunflower, power, dots }
    let kind: Kind

    static func kind(for symbol: String) -> Kind? {
        switch symbol {
        case "music.note": return .music
        case "tray.full.fill": return .basket
        case "camera.fill": return .easel
        case "gearshape.fill": return .sunflower
        case "power": return .power
        case "ellipsis": return .dots
        default: return nil
        }
    }

    var body: some View {
        let style = StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round)
        ZStack {
            // Lớp lệch mờ phía sau cho cảm giác nét cọ hai lần quệt.
            VGIconShape(kind: kind).stroke(style: style).opacity(0.35).offset(x: 0.6, y: 0.5)
            VGIconShape(kind: kind).stroke(style: style)
            if kind == .music {
                Ellipse().frame(width: 5.4, height: 4.2).rotationEffect(.degrees(-20)).offset(x: -3, y: 4)
            }
        }
        .frame(width: 16, height: 15)
    }
}

struct VGIconShape: Shape {
    let kind: VGIcon.Kind

    func path(in r: CGRect) -> Path {
        let sx = r.width / 16, sy = r.height / 15
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        switch kind {
        case .music:
            path.move(to: p(7.4, 11)); path.addLine(to: p(7.4, 2.4))
            path.addQuadCurve(to: p(12.6, 7.6), control: p(11.6, 3.6))
        case .basket:
            path.move(to: p(2, 6.2)); path.addLine(to: p(14, 6.2)); path.addLine(to: p(12.3, 13.6))
            path.addLine(to: p(3.7, 13.6)); path.closeSubpath()
            path.move(to: p(4.2, 6.2)); path.addQuadCurve(to: p(11.8, 6.2), control: p(8, -0.8))
            path.move(to: p(2.9, 8.8)); path.addQuadCurve(to: p(13.1, 8.8), control: p(8, 9.9))
            path.move(to: p(3.4, 11.2)); path.addQuadCurve(to: p(12.6, 11.2), control: p(8, 12.3))
            path.move(to: p(6.2, 6.2)); path.addLine(to: p(6.6, 13.6))
            path.move(to: p(9.8, 6.2)); path.addLine(to: p(9.4, 13.6))
        case .easel:
            path.addRoundedRect(in: CGRect(x: r.minX + 2.6 * sx, y: r.minY + 2 * sy, width: 10.8 * sx, height: 7.6 * sy),
                                cornerSize: CGSize(width: 1, height: 1))
            path.move(to: p(5, 9.6)); path.addLine(to: p(3, 14.6))
            path.move(to: p(11, 9.6)); path.addLine(to: p(13, 14.6))
            path.move(to: p(8, 9.6)); path.addLine(to: p(8, 14.6))
            path.move(to: p(5.4, 7)); path.addQuadCurve(to: p(8.2, 5.6), control: p(6.4, 4.4))
            path.addQuadCurve(to: p(10.8, 5.2), control: p(9.6, 7.2))
        case .sunflower:
            let c = p(8, 7.5)
            path.addEllipse(in: CGRect(x: c.x - 2.4 * sx, y: c.y - 2.4 * sy, width: 4.8 * sx, height: 4.8 * sy))
            for i in 0..<8 {
                let a = Double(i) * .pi / 4 + 0.2
                path.move(to: CGPoint(x: c.x + cos(a) * 4.2 * sx, y: c.y + sin(a) * 4.2 * sy))
                path.addLine(to: CGPoint(x: c.x + cos(a) * 6.8 * sx, y: c.y + sin(a) * 6.8 * sy))
            }
        case .power:
            path.addArc(center: p(8, 8.6), radius: 5.2 * sx, startAngle: .degrees(-55), endAngle: .degrees(235), clockwise: false)
            path.move(to: p(8, 1.8)); path.addLine(to: p(8, 7.6))
        case .dots:
            // Ba chấm sơn ngắn.
            for x in [3.0, 8.0, 13.0] as [CGFloat] {
                let c = p(x, 8)
                path.addEllipse(in: CGRect(x: c.x - 1.2 * sx, y: c.y - 1.1 * sy, width: 2.4 * sx, height: 2.2 * sy))
            }
        }
        return path
    }
}

/// Mảng sơn vàng quệt tay cho tab đang chọn: mép nham nhở, vài vệt cọ đậm nhạt bên trong.
struct VGSwash: View {
    var body: some View {
        ZStack {
            VGSwashShape().fill(VG.yellow)
            VGSwashShape().fill(LinearGradient(colors: [.white.opacity(0.35), .clear, VG.yellow2.opacity(0.6)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, size in
                let strokes: [(CGFloat, CGFloat, CGFloat, Color)] = [
                    (0.18, 0.32, 0.55, VG.yellow2), (0.3, 0.7, 0.62, Color(red: 1, green: 0.88, blue: 0.5)),
                    (0.55, 0.45, 0.4, VG.yellow2), (0.12, 0.55, 0.3, Color(red: 1, green: 0.93, blue: 0.62)),
                ]
                for (x, y, len, col) in strokes {
                    var s = Path()
                    s.move(to: CGPoint(x: size.width * x, y: size.height * y))
                    s.addQuadCurve(to: CGPoint(x: size.width * (x + len), y: size.height * (y - 0.06)),
                                   control: CGPoint(x: size.width * (x + len / 2), y: size.height * (y + 0.12)))
                    ctx.stroke(s, with: .color(col.opacity(0.75)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
            .clipShape(VGSwashShape())
            VGSwashShape().stroke(VG.ink.opacity(0.85), lineWidth: 1.2)
            Canvas { ctx, size in
                for (y, len, op) in [(0.3, 7.0, 0.8), (0.5, 10.0, 0.65), (0.7, 6.0, 0.5)] as [(CGFloat, CGFloat, Double)] {
                    var s = Path()
                    s.move(to: CGPoint(x: size.width - 4, y: size.height * y))
                    s.addLine(to: CGPoint(x: size.width - 4 + len, y: size.height * y + 0.6))
                    ctx.stroke(s, with: .color(VG.yellow.opacity(op)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            .allowsHitTesting(false)
        }
        .rotationEffect(.degrees(-2))
        .padding(.horizontal, -3)
        .padding(.vertical, -1)
    }
}

/// Viên thuốc có mép hơi gợn, cố định (không ngẫu nhiên mỗi lần vẽ).
struct VGSwashShape: Shape {
    func path(in r: CGRect) -> Path {
        let rad = r.height / 2
        let straight = max(r.width - 2 * rad, 0)
        let total = 2 * straight + 2 * .pi * rad
        let n = 44
        func point(_ d: CGFloat) -> (CGPoint, CGPoint) {
            // (điểm trên chu vi, pháp tuyến hướng ra ngoài)
            var d = d
            if d < straight { return (CGPoint(x: r.minX + rad + d, y: r.minY), CGPoint(x: 0, y: -1)) }
            d -= straight
            if d < .pi * rad {
                let a = -CGFloat.pi / 2 + d / rad
                let c = CGPoint(x: r.maxX - rad, y: r.midY)
                return (CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad), CGPoint(x: cos(a), y: sin(a)))
            }
            d -= .pi * rad
            if d < straight { return (CGPoint(x: r.maxX - rad - d, y: r.maxY), CGPoint(x: 0, y: 1)) }
            d -= straight
            let a = CGFloat.pi / 2 + d / rad
            let c = CGPoint(x: r.minX + rad, y: r.midY)
            return (CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad), CGPoint(x: cos(a), y: sin(a)))
        }
        let pts: [CGPoint] = (0..<n).map { i in
            let (pt, nrm) = point(total * CGFloat(i) / CGFloat(n))
            let w = 0.55 * sin(CGFloat(i) * 2.7) + 0.35 * sin(CGFloat(i) * 6.1 + 0.8)
            return CGPoint(x: pt.x + nrm.x * w, y: pt.y + nrm.y * w)
        }
        var path = Path()
        path.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Đổi tab: quét cọ

/// Hình học chung cho mặt nạ và lớp sơn: 3 vệt cọ chéo nối đuôi nhau, mép trên/dưới lượn,
/// đầu vệt là các sợi lông cọ dài ngắn khác nhau (khe hở giữa sợi = vệt cọ khô).
private enum VGWipeGeo {
    static let bands = 3
    static let fibers = 16
    static let angle: CGFloat = -0.14

    static func reach(_ i: Int, _ progress: CGFloat) -> CGFloat {
        min(max((progress - CGFloat(i) * 0.16) / 0.62, 0), 1)
    }

    /// Độ dài sợi cọ thứ k của vệt i (cố định).
    static func fiber(_ i: Int, _ k: Int) -> CGFloat {
        let v = sin(CGFloat(k * 7 + i * 13) * 1.7) * 0.5 + 0.5
        return 6 + v * 26
    }

    /// Duyệt từng sợi: (vệt, sợi, khung sợi trong hệ trục chưa xoay, độ tiến của vệt).
    static func forEachFiber(in r: CGRect, progress: CGFloat, _ body: (Int, Int, CGRect, CGFloat) -> Void) {
        let big = r.insetBy(dx: -r.height * 0.3, dy: -r.width * 0.12)
        let bandH = big.height / CGFloat(bands)
        for i in 0..<bands {
            let reach = Self.reach(i, progress)
            guard reach > 0 else { continue }
            let y0 = big.minY + CGFloat(i) * bandH - 8
            let h = bandH + 16
            let head = big.minX - 40 + (big.width + 80) * reach
            let fh = h / CGFloat(fibers)
            for k in 0..<fibers {
                let wave = sin(CGFloat(k) / CGFloat(fibers) * .pi) * 10   // đầu vệt hơi cong như đầu cọ
                let len = head + wave + fiber(i, k) - big.minX
                body(i, k, CGRect(x: big.minX, y: y0 + CGFloat(k) * fh, width: max(len, 0), height: fh * 0.86), reach)
            }
        }
    }

    static func rotation(_ r: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: angle).translatedBy(x: -r.midX, y: -r.midY)
    }
}

private struct VGBrushWipeMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        guard progress < 1 else { return Path(r.insetBy(dx: -40, dy: -40)) }
        var p = Path()
        VGWipeGeo.forEachFiber(in: r, progress: progress) { _, _, rect, _ in
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
            // Thân vệt liền (khe giữa sợi chỉ ở đầu cọ), phủ cả khe lên sợi kế bên.
            if rect.width > 46 {
                p.addRect(CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width - 40, height: rect.height * 1.3))
            }
        }
        return p.applying(VGWipeGeo.rotation(r))
    }
}

struct VGBrushWipe: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask(VGBrushWipeMask(progress: progress))
            .overlay {
                if progress > 0, progress < 1 {
                    // Sơn ướt ở đầu mỗi vệt: các sợi màu vàng / xanh / kem, mờ dần khi vệt đi hết.
                    Canvas { ctx, size in
                        let r = CGRect(origin: .zero, size: size)
                        let colors: [Color] = [VG.yellow, VG.cobalt, VG.cream, VG.yellow2, Color(red: 0.55, green: 0.7, blue: 0.9)]
                        ctx.concatenate(VGWipeGeo.rotation(r))
                        VGWipeGeo.forEachFiber(in: r, progress: progress) { i, k, rect, reach in
                            guard reach < 1 else { return }
                            let fade = Double(1 - reach)
                            let tail = min(rect.width, 70 + CGFloat((k * 5 + i) % 4) * 18)
                            let fiber = CGRect(x: rect.maxX - tail, y: rect.minY, width: tail, height: rect.height)
                            ctx.fill(Path(roundedRect: fiber, cornerRadius: rect.height / 2),
                                     with: .linearGradient(Gradient(colors: [colors[(k + i) % colors.count].opacity(0), colors[(k + i) % colors.count].opacity(0.9 * fade)]),
                                                           startPoint: CGPoint(x: fiber.minX, y: fiber.midY),
                                                           endPoint: CGPoint(x: fiber.maxX, y: fiber.midY)))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}
