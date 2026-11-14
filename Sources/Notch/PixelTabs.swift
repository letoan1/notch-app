import AppKit
import CoreImage
import SwiftUI

/// Giao diện Pixel 8-bit kiểu máy chơi game thùng: thanh EXP + LEVEL UP (nhạc), bản đồ chọn màn (lịch),
/// ô đồ đạc + rương (khay), selfie 8-bit (gương), hộp thoại nhập vai (Claude). Sprite tự vẽ.

// MARK: - Sprite

enum PixelArt {
    static let ink = Color(red: 0.05, green: 0.04, blue: 0.12)
    static let panel = Color(red: 0.08, green: 0.07, blue: 0.18)
    static let yellow = Color(red: 1, green: 0.9, blue: 0.43)
    static let green = Color(red: 0.45, green: 0.93, blue: 0.45)
    static let cyan = Color(red: 0.4, green: 0.86, blue: 1)

    static let monsterA = ["..1111..", ".111111.", "1k1111k1", "11111111", "1.1..1.1", "11.11.11"]
    static let monsterB = ["1......1", ".1....1.", ".111111.", "11k11k11", "11111111", ".1.11.1."]
    static let monsterBig = ["...1111...", ".11111111.", "1111111111", "11k1111k11", "1111111111", "11.1111.11", "1..1..1..1"]
    static let flag = ["12222.", "122222", "12222.", "1.....", "1.....", "1....."]
    static let chestClosed = [
        "................", "................", "................",
        "..222222222222..", ".23333333333332.", "2333333333333332", "2222222442222222",
        "2111111441111112", "2111111551111112", "2111111111111112", "2111111111111112", "2222222222222222",
    ]
    static let chestOpen = [
        "..222222222222..", ".23333333333332.", ".26666666666662.", "..222222222222..",
        "....7..7...7....", "..777.7777.777..", "2777777777777772", "2222222442222222",
        "2111111441111112", "2111111551111112", "2111111111111112", "2222222222222222",
    ]
    static let sparkle = ["..7..", "..7..", "77777", "..7..", "..7.."]

    static let chestPalette: [Character: Color] = [
        "1": Color(red: 0.62, green: 0.38, blue: 0.2), "2": Color(red: 0.25, green: 0.13, blue: 0.07),
        "3": Color(red: 0.78, green: 0.5, blue: 0.27), "4": yellow, "5": ink, "7": yellow,
        "6": Color(red: 0.16, green: 0.08, blue: 0.05),
    ]

    /// Ảnh CGImage của sprite (cho layer Core Animation).
    static func image(_ rows: [String], palette: [Character: NSColor], cell: Int = 2) -> CGImage? {
        let cols = rows.map(\.count).max() ?? 1
        let w = cols * cell, h = rows.count * cell
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let col = palette[ch] else { continue }
                ctx.setFillColor(col.cgColor)
                ctx.fill(CGRect(x: c * cell, y: (rows.count - 1 - r) * cell, width: cell, height: cell))
            }
        }
        return ctx.makeImage()
    }
}

/// Sprite nhiều màu vẽ theo lưới, ô vuông sắc.
struct PixelSprite: View {
    let rows: [String]
    let palette: [Character: Color]

    var body: some View {
        Canvas { ctx, size in
            let cols = rows.map(\.count).max() ?? 1
            let cell = max(1, floor(min(size.width / CGFloat(cols), size.height / CGFloat(rows.count))))
            let x0 = floor((size.width - cell * CGFloat(cols)) / 2), y0 = floor((size.height - cell * CGFloat(rows.count)) / 2)
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() {
                    guard let col = palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: x0 + CGFloat(c) * cell, y: y0 + CGFloat(r) * cell, width: cell, height: cell)), with: .color(col))
                }
            }
        }
    }
}

/// Sprite nhấp nháy bằng Core Animation (render server lo, app không vẽ lại).
struct PixelBlink: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = CALayer()
        l.contents = image
        l.magnificationFilter = .nearest
        l.contentsGravity = .resizeAspect
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1, 1, 0.15, 0.15]
        anim.keyTimes = [0, 0.5, 0.5, 1]
        anim.calculationMode = .discrete
        anim.duration = 1
        anim.repeatCount = .infinity
        l.add(anim, forKey: "blink")
        v.layer?.addSublayer(l)
        context.coordinator.layer = l
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        context.coordinator.layer?.frame = view.bounds
        CATransaction.commit()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var layer: CALayer? }
}

// MARK: - Nhạc: EXP + LEVEL UP

/// Số bài đã nghe hết trong phiên (≥ 90% rồi mới đổi bài hoặc dừng) = cấp độ.
@MainActor
final class ArcadeStats: ObservableObject {
    static let shared = ArcadeStats()
    @Published private(set) var level = 0
    @Published private(set) var levelUps = 0

    func trackChanged(from old: Track?, to new: Track?) {
        guard let old, old.duration > 0 else { return }
        if let new, new.title == old.title, new.artist == old.artist { return }
        if old.position(at: Date()) / old.duration >= 0.9 {
            level += 1
            levelUps += 1
        }
    }
}

/// "LV n" + chữ EXP, đặt trước thanh tiến độ của theme Pixel.
struct PixelLevelTag: View {
    @ObservedObject var stats = ArcadeStats.shared

    var body: some View {
        HStack(spacing: 4) {
            Text("LV\(stats.level)").foregroundStyle(PixelArt.yellow)
            Text("EXP").foregroundStyle(PixelArt.green.opacity(0.85))
        }
        .fixedSize()
    }
}

/// Băng rôn "LEVEL UP!" hiện ~1,2 s mỗi khi lên cấp (chỉ khi notch đang mở).
struct PixelLevelUpBanner: View {
    @ObservedObject var stats = ArcadeStats.shared
    private var shown = State(initialValue: false)

    var body: some View {
        ZStack {
            if shown.wrappedValue {
                VStack(spacing: 0) {
                    Text("LEVEL UP!")
                        .font(.custom("VT323", size: 34))
                        .foregroundStyle(PixelArt.yellow)
                        .shadow(color: Color(red: 0.9, green: 0.2, blue: 0.4), radius: 0, x: 2, y: 2)
                    Text("LV \(stats.level)")
                        .font(.custom("VT323", size: 18))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(Rectangle().fill(PixelArt.ink.opacity(0.92)))
                .overlay(Rectangle().strokeBorder(PixelArt.yellow, lineWidth: 3))
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: stats.levelUps) { _, _ in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { shown.wrappedValue = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.15)) { shown.wrappedValue = false }
            }
        }
    }
}

// MARK: - Lịch: bản đồ chọn màn

/// Đường chấm nối các ô ngày (vẽ sau ô số).
struct PixelMapPath: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: size.height / 2 - 1, width: 2, height: 2)), with: .color(PixelPalette.dim))
                x += 5
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
    }
}

/// Quái vật nhỏ trên ngày có sự kiện: 1 con, 2 con, rồi 1 con to.
struct PixelMonsters: View {
    let load: Int

    var body: some View {
        HStack(spacing: 1) {
            if load >= 3 {
                PixelSprite(rows: PixelArt.monsterBig, palette: ["1": Color(red: 1, green: 0.42, blue: 0.5), "k": PixelArt.ink])
                    .frame(width: 20, height: 14)
            } else if load == 2 {
                PixelSprite(rows: PixelArt.monsterA, palette: ["1": PixelArt.green, "k": PixelArt.ink]).frame(width: 9, height: 7)
                PixelSprite(rows: PixelArt.monsterB, palette: ["1": Color(red: 0.72, green: 0.55, blue: 1), "k": PixelArt.ink]).frame(width: 9, height: 7)
            } else if load == 1 {
                PixelSprite(rows: PixelArt.monsterA, palette: ["1": PixelArt.green, "k": PixelArt.ink]).frame(width: 9, height: 7)
            }
        }
        .frame(height: 14)
    }
}

/// Cờ nhấp nháy trên ngày hôm nay.
struct PixelTodayFlag: View {
    private static let image = PixelArt.image(PixelArt.flag, palette: [
        "1": .white, "2": NSColor(red: 1, green: 0.3, blue: 0.35, alpha: 1),
    ], cell: 2)

    var body: some View {
        PixelBlink(image: Self.image).frame(width: 10, height: 10)
    }
}

// MARK: - Khay: ô đồ đạc + rương

struct PixelTrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool
    private var menu = State<TrayMenuTarget?>(initialValue: nil)

    init(tray: TrayStore, targeted: Bool) {
        self.tray = tray
        self.targeted = targeted
    }

    var body: some View {
        HStack(spacing: 14) {
            if !tray.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    TrayFilterBar(tray: tray)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tray.visibleFiles, id: \.self) { url in
                                PixelItemSlot(url: url, tray: tray, selected: tray.selection.contains(url),
                                              remove: { tray.remove(url) },
                                              onMenu: { menu.wrappedValue = .init(url: url, point: $0) })
                                    .modifier(PixelPlusOne(url: url, tray: tray))
                                    .modifier(TrayRemovalEffect(tray: tray, url: url))
                            }
                            ForEach(0..<max(0, 5 - tray.visibleFiles.count), id: \.self) { _ in
                                PixelEmptySlot()
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 4)
                        .frame(maxHeight: .infinity)
                        // Ô trống bù vào chỗ file vừa gỡ (sau khi hiệu ứng vỡ chạy xong).
                        .animation(.easeOut(duration: 0.2), value: tray.visibleFiles)
                    }
                }
                .background(Color.black.opacity(0.001).onTapGesture { tray.selection = [] })
            }
            PixelChestZone(targeted: targeted, wide: tray.files.isEmpty)
                .frame(width: tray.files.isEmpty ? nil : 140)
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

private struct PixelSlotFrame: View {
    let selected: Bool
    let hover: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(PixelPalette.shadow).offset(x: 3, y: 3)
            Rectangle().fill(hover ? Color(red: 0.14, green: 0.12, blue: 0.28) : PixelArt.panel)
            Rectangle().strokeBorder(selected ? PixelPalette.pink : PixelPalette.dim, lineWidth: selected ? 3 : 2)
            // Góc sáng kiểu ô vật phẩm.
            Rectangle().fill(.white.opacity(0.18)).frame(width: 6, height: 2).padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct PixelEmptySlot: View {
    var body: some View {
        VStack(spacing: 4) {
            PixelSlotFrame(selected: false, hover: false).opacity(0.45).frame(width: 62, height: 62)
            Text(" ").font(.ui(10))
        }
        .allowsHitTesting(false)
    }
}

private struct PixelItemSlot: View {
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
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                PixelSlotFrame(selected: selected, hover: hover.wrappedValue)
                Group {
                    if FileThumbnails.isVisual(url) {
                        PixelThumb(url: url).frame(width: 42, height: 42)
                            .overlay(Rectangle().strokeBorder(PixelPalette.border, lineWidth: 2))
                    } else {
                        PixelDocItem(url: url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("x1")
                    .font(.custom("VT323", size: 14))
                    .foregroundStyle(.white)
                    .shadow(color: PixelArt.ink, radius: 0, x: 1, y: 1)
                    .padding(.trailing, 5).padding(.bottom, 1)
            }
            .frame(width: 62, height: 62)
            Text(url.lastPathComponent.precomposedStringWithCanonicalMapping)
                .font(.ui(10))
                .foregroundStyle(PixelPalette.border)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 70)
        }
        .overlay(TrayItemInteraction(url: url, tray: tray))
        .overlay(alignment: .topTrailing) {
            if hover.wrappedValue {
                Button(action: remove) {
                    Text("X")
                        .font(.custom("VT323", size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Rectangle().fill(PixelPalette.pink))
                        .overlay(Rectangle().strokeBorder(PixelArt.ink, lineWidth: 1))
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

/// Ảnh xem trước thu về ô pixel (giảm màu), phóng to giữ ô sắc.
private struct PixelThumb: View {
    let url: URL
    private var image: State<NSImage?>

    init(url: URL) {
        self.url = url
        image = State(initialValue: FileThumbnails.cached(url, size: CGSize(width: 64, height: 64)).map { $0.pixelated(24) })
    }

    var body: some View {
        Group {
            if let img = image.wrappedValue {
                Image(nsImage: img).resizable().interpolation(.none)
            } else {
                Rectangle().fill(PixelPalette.shadow)
            }
        }
        .task(id: url) {
            if let img = await FileThumbnails.load(url, size: CGSize(width: 64, height: 64)) {
                image.wrappedValue = img.pixelated(24)
            }
        }
    }
}

/// Vật phẩm tài liệu: tờ giấy góc cắt vuông, nhãn đuôi file.
private struct PixelDocItem: View {
    let url: URL

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(fileTint(url))
                .overlay(Rectangle().strokeBorder(PixelPalette.border, lineWidth: 2))
            Rectangle().fill(PixelArt.panel).frame(width: 9, height: 9)
            Rectangle().fill(PixelPalette.border).frame(width: 9, height: 2).offset(y: 9)
            Rectangle().fill(PixelPalette.border).frame(width: 2, height: 11).offset(x: -9)
            Text(label)
                .font(.custom("VT323", size: 13))
                .foregroundStyle(.white)
                .shadow(color: PixelArt.ink, radius: 0, x: 1, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 3)
        }
        .frame(width: 34, height: 42)
    }

    private var label: String {
        if url.hasDirectoryPath { return "DIR" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }
}

/// Vật phẩm mới: "+1 ITEM" bay lên rồi tan (lần đầu tile hiện ra).
private struct PixelPlusOne: ViewModifier {
    private var progress: State<CGFloat>
    private let url: URL
    private let tray: TrayStore

    init(url: URL, tray: TrayStore) {
        self.url = url
        self.tray = tray
        progress = State(initialValue: tray.fresh.contains(url) ? 0 : 1)
    }

    func body(content: Content) -> some View {
        let p = progress.wrappedValue
        content
            .scaleEffect(p < 0.25 ? 0.7 + p * 1.2 : 1)
            .overlay(alignment: .top) {
                Text("+1 ITEM")
                    .font(.custom("VT323", size: 16))
                    .foregroundStyle(PixelArt.yellow)
                    .shadow(color: PixelArt.ink, radius: 0, x: 1, y: 1)
                    .fixedSize()
                    .offset(y: -6 - 26 * p)
                    .opacity(p >= 1 ? 0 : Double(1 - p * p))
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard tray.takeFresh(url) else { return }
                progress.wrappedValue = 0
                withAnimation(.easeOut(duration: 0.9)) { progress.wrappedValue = 1 }
            }
    }
}

/// Gỡ vật phẩm: vỡ thành ô vuông rơi xuống và mờ dần.
struct PixelShatter: ViewModifier, Animatable {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(Double(max(0, 1 - amount * 4)))
            .overlay {
                if amount > 0 {
                    Canvas { ctx, size in
                        var rng = SeededRNG(41)
                        let colors = [PixelPalette.pink, PixelPalette.border, PixelArt.yellow, PixelPalette.dim]
                        let n = 5, cell: CGFloat = 8
                        let t = amount
                        for i in 0..<n {
                            for j in 0..<n {
                                let x0 = size.width / 2 + (CGFloat(i) - CGFloat(n) / 2) * cell * 1.4
                                let y0 = size.height / 2 + (CGFloat(j) - CGFloat(n) / 2) * cell * 1.4 - 8
                                let vx = CGFloat(rng.range(-55, 55)), vy = CGFloat(rng.range(-60, -15))
                                let x = x0 + vx * t, y = y0 + vy * t + 170 * t * t
                                ctx.opacity = Double(1 - t)
                                ctx.fill(Path(CGRect(x: floor(x), y: floor(y), width: cell, height: cell)),
                                         with: .color(colors[(i + j) % colors.count]))
                            }
                        }
                    }
                    .padding(-30)
                    .allowsHitTesting(false)
                }
            }
    }
}

/// Ô thả: rương kho báu, kéo file tới thì mở nắp.
private struct PixelChestZone: View {
    let targeted: Bool
    let wide: Bool

    var body: some View {
        Rectangle()
            .fill(PixelArt.panel)
            .overlay(Rectangle().stroke(PixelPalette.border.opacity(targeted ? 1 : 0.8),
                                        style: StrokeStyle(lineWidth: 4, dash: [8, 8])))
            .overlay {
                if wide {
                    HStack(spacing: 22) {
                        chest.frame(width: 96, height: 66)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(targeted ? L("Thả vào rương!", "Drop it in the chest!")
                                          : L("Kéo file lên notch để cất vào rương", "Drag files onto the notch to stash them"))
                                .font(.ui(14))
                                .foregroundStyle(PixelArt.yellow)
                            Text(L("Kéo ra để thả vào bất cứ đâu. Chuột phải để AirDrop hoặc chia sẻ.",
                                   "Drag out to drop anywhere. Right-click to AirDrop or share."))
                                .font(.ui(11))
                                .foregroundStyle(PixelPalette.border.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 300, alignment: .leading)
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 6) {
                        chest.frame(width: 56, height: 38)
                        Text(L("Thả vào rương", "Drop here"))
                            .font(.ui(12))
                            .foregroundStyle(PixelArt.yellow)
                    }
                }
            }
            .scaleEffect(targeted ? 1.03 : 1)
    }

    private var chest: some View {
        ZStack {
            PixelSprite(rows: targeted ? PixelArt.chestOpen : PixelArt.chestClosed, palette: PixelArt.chestPalette)
            if targeted {
                PixelSprite(rows: PixelArt.sparkle, palette: ["7": PixelArt.yellow]).frame(width: 12, height: 12).offset(x: -34, y: -26)
                PixelSprite(rows: PixelArt.sparkle, palette: ["7": .white]).frame(width: 10, height: 10).offset(x: 36, y: -20)
                PixelSprite(rows: PixelArt.sparkle, palette: ["7": PixelArt.cyan]).frame(width: 8, height: 8).offset(x: 8, y: -34)
            }
        }
        .offset(y: targeted ? -2 : 0)
    }
}

// MARK: - Gương: selfie 8-bit

enum PixelCam {
    /// Thu nhỏ còn 112 ô ngang + giảm màu: chạy trên GPU, ảnh ra rất nhỏ nên gần như không tốn.
    static func pixel8(_ img: CIImage) -> CIImage {
        let s = 112 / max(img.extent.width, 1)
        var out = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputContrastKey: 1.12])
        out = out.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 5])
        let e = out.extent.integral
        return out.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}

struct PixelMirrorView: View {
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
            ZStack {
                preview
                if flash.wrappedValue { Rectangle().fill(.white).transition(.opacity) }
            }
            .frame(width: 300)
            .overlay(Rectangle().strokeBorder(PixelPalette.border, lineWidth: 3))
            .background(Rectangle().fill(PixelPalette.shadow).offset(x: 4, y: 4))
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Sẵn sàng họp?", "Ready for the call?"))
                    .font(.ui(15))
                    .foregroundStyle(PixelArt.yellow)
                meeting
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    chip(L("Selfie 8-bit", "8-bit selfie"), on: camera.pixelSelfie) { camera.pixelSelfie.toggle() }
                        .help(L("Biến hình camera thành ảnh pixel 8-bit", "Turn the camera into 8-bit pixels"))
                    if camera.pixelSelfie && camera.access == .granted {
                        chip(L("Chụp avatar", "Save avatar"), on: true, fill: PixelArt.yellow, action: capture)
                            .help(L("Lưu avatar pixel vào khay và thư mục Ảnh › Roost", "Save the pixel avatar to the tray and Pictures › Roost"))
                    }
                }
                HStack(spacing: 8) {
                    chip(camera.mirrored ? L("Lật: gương", "Flip: mirror") : L("Lật: thật", "Flip: true"), on: false) { camera.mirrored.toggle() }
                    chip(edge.level.title, on: edge.isOn) { edge.cycle() }
                        .help(L("Viền sáng quanh màn hình để rọi mặt khi gọi video · bấm để đổi mức / tắt", "A glowing screen border that lights your face on calls · click to change level / turn off"))
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder private var preview: some View {
        switch camera.access {
        case .granted:
            Group {
                if camera.pixelSelfie {
                    PainterlyPreview(camera: camera, cornerRadius: 0, pixelated: true)
                } else {
                    CameraPreview(session: camera.session, cornerRadius: 0, mirrored: camera.mirrored)
                }
            }
            .overlay { if camera.frameState == .live { MirrorGuideOverlay(hint: camera.guide) } }
            .overlay { if camera.frameState != .live { noFrames } }
        case .notDetermined:
            placeholder(L("Bật camera để soi gương", "Turn on the camera"), action: camera.requestAccess)
        case .denied:
            placeholder(L("Mở Cài đặt để cấp quyền camera", "Open Settings to allow camera access"), action: camera.openPrivacySettings)
        }
    }

    private var noFrames: some View {
        let starting = camera.frameState == .starting
        return Rectangle().fill(PixelArt.panel)
            .overlay(VStack(spacing: 6) {
                Text(starting ? L("Đang bật camera…", "Starting the camera…") : L("Camera chưa có hình", "No picture from the camera"))
                    .font(.ui(14)).foregroundStyle(PixelArt.yellow)
                if !starting {
                    Text(L("Mở nắp máy, hoặc tắt app khác đang dùng camera", "Open the lid, or quit other apps using the camera"))
                        .font(.ui(11)).foregroundStyle(PixelPalette.border.opacity(0.8))
                        .multilineTextAlignment(.center).padding(.horizontal, 16)
                }
            })
            .allowsHitTesting(false)
    }

    private func placeholder(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Rectangle().fill(PixelArt.panel)
                .overlay(Text(text).font(.ui(13)).foregroundStyle(PixelPalette.border).multilineTextAlignment(.center))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var meeting: some View {
        if let next = calendar.nextEvent {
            HStack(spacing: 6) {
                PixelSprite(rows: PixelArt.monsterA, palette: ["1": PixelArt.green, "k": PixelArt.ink]).frame(width: 14, height: 11)
                VStack(alignment: .leading, spacing: 0) {
                    Text(next.title).font(.ui(12)).foregroundStyle(.white).lineLimit(1)
                    Text(Self.untilText(next)).font(.ui(10)).foregroundStyle(PixelPalette.border.opacity(0.7))
                }
                if let link = next.meeting {
                    Spacer(minLength: 4)
                    JoinButton(meeting: link, prominent: true)
                }
            }
        } else {
            Text(calendar.access == .granted ? L("Hôm nay hết họp rồi", "No more meetings today") : L("Soi lại trước khi lên hình", "Check yourself before the call"))
                .font(.ui(11)).foregroundStyle(PixelPalette.border.opacity(0.75))
        }
    }

    private static func untilText(_ item: CalendarStore.Item) -> String {
        let minutes = Int(item.start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return L("Đang diễn ra", "Happening now") }
        return L("Sau \(minutes) phút", "In \(minutes) min")
    }

    private func chip(_ title: String, on: Bool, fill: Color = PixelPalette.pink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11))
                .foregroundStyle(on ? PixelArt.ink : .white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(ThemedBackground(fill: on ? fill : PixelArt.panel))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func capture() {
        withAnimation(.easeOut(duration: 0.06)) { flash.wrappedValue = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.2)) { flash.wrappedValue = false }
        }
        Haptics.tap(.levelChange)
        camera.painter.capture(mirrored: camera.mirrored, name: "Avatar 8-bit", upscale: 8) { url in
            guard let url else { return }
            tray.add(url)
        }
    }
}

// MARK: - Claude: hộp thoại nhập vai

/// Khung hộp thoại hai lớp viền pixel.
struct PixelDialogFrame: View {
    var body: some View {
        ZStack {
            Rectangle().fill(PixelPalette.shadow).offset(x: 4, y: 4)
            Rectangle().fill(Color(red: 0.05, green: 0.05, blue: 0.16))
            Rectangle().strokeBorder(PixelPalette.border, lineWidth: 3)
            Rectangle().strokeBorder(PixelPalette.dim, lineWidth: 2).padding(6)
        }
    }
}

/// Chữ hiện ra từng ký tự (nhanh, tối đa ~0,9 s), bấm để hiện hết. Chỉ chạy một lần.
struct PixelTyped: View {
    let text: String
    var font: Font = .ui(12)
    var color: Color = .white
    var lineLimit = 2
    private var started = State(initialValue: Date())
    private var done = State(initialValue: false)

    init(text: String, font: Font = .ui(12), color: Color = .white, lineLimit: Int = 2) {
        self.text = text
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
    }

    private var step: Double { min(0.025, 0.9 / Double(max(text.count, 1))) }

    var body: some View {
        Group {
            if done.wrappedValue || SystemMonitor.shared.lowPower {
                label(text)
            } else {
                TimelineView(.periodic(from: started.wrappedValue, by: step)) { ctx in
                    let n = Int(ctx.date.timeIntervalSince(started.wrappedValue) / step)
                    label(String(text.prefix(n)) + (n < text.count ? "▌" : ""))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { done.wrappedValue = true }
        .onAppear {
            started.wrappedValue = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(text.count) + 0.05) { done.wrappedValue = true }
        }
    }

    private func label(_ s: String) -> some View {
        // Chữ đủ dài sẵn (ẩn phần chưa gõ) để khung không nhảy theo từng ký tự.
        ZStack(alignment: .topLeading) {
            Text(text).font(font).hidden()
            Text(s).font(font).foregroundStyle(color)
        }
        .lineLimit(lineLimit)
        .truncationMode(.middle)
    }
}

/// Dòng lựa chọn có con trỏ ▶ đi theo chuột.
struct PixelChoice: View {
    let title: String
    let selected: Bool
    var tint: Color = .white
    let hover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("▶").foregroundStyle(PixelPalette.pink).opacity(selected ? 1 : 0)
                Text(title).foregroundStyle(selected ? PixelArt.yellow : tint)
            }
            .font(.ui(13))
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
    }
}

struct PixelDialogCard: View {
    let request: PermissionRequest
    let pending: Int
    let decide: (PermissionDecision) -> Void
    private var cursor = State(initialValue: 0)

    init(request: PermissionRequest, pending: Int, decide: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.pending = pending
        self.decide = decide
    }

    private var waiting: Bool { request.state.isWaiting }

    private var choices: [(String, PermissionDecision)] {
        var list: [(String, PermissionDecision)] = [(request.kind == .plan ? L("Duyệt kế hoạch", "Approve plan") : L("Cho phép", "Allow"), .allow)]
        if request.canAlwaysAllow { list.append((request.alwaysTitle, .allowAlways)) }
        list.append((request.kind == .plan ? L("Chưa duyệt", "Keep planning") : L("Từ chối", "Deny"), .deny))
        return list
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    // "Chân dung" người nói kiểu hộp thoại game: ngôi sao cam của Claude.
                    PixelSprite(rows: PixelArt.sparkle, palette: ["7": ClaudeInk.claude])
                        .frame(width: 14, height: 14)
                        .padding(2)
                        .background(Rectangle().fill(PixelArt.ink))
                        .overlay(Rectangle().strokeBorder(ClaudeInk.claude, lineWidth: 2))
                    Text(request.kindTitle).font(.ui(12)).foregroundStyle(.white)
                    if request.kind == .tool {
                        Text(request.tool).font(.ui(11)).foregroundStyle(PixelArt.cyan)
                    }
                }
                .lineLimit(1)
                OriginRow(request: request)
                VStack(alignment: .leading, spacing: 1) {
                    PixelTyped(text: request.summary.isEmpty ? " " : request.summary,
                               font: .ui(12), color: .white, lineLimit: request.detail == nil ? 3 : 2)
                        .help(request.summary)
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail).font(.ui(10.5)).foregroundStyle(PixelPalette.border.opacity(0.65)).lineLimit(1)
                    }
                }
                .opacity(waiting ? 1 : 0.55)
                Spacer(minLength: 0)
                ScopeLine(request: request)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("TIME").font(.ui(10)).foregroundStyle(PixelPalette.border.opacity(0.8))
                    CountdownBadge(request: request)
                }
                if waiting {
                    ForEach(Array(choices.enumerated()), id: \.offset) { i, choice in
                        PixelChoice(title: choice.0, selected: cursor.wrappedValue == i,
                                    tint: choice.1 == .deny ? PixelPalette.border.opacity(0.8) : .white,
                                    hover: { if $0 { cursor.wrappedValue = i } }) { decide(choice.1) }
                            .help(choice.1 == .allowAlways ? request.alwaysHelp : "")
                    }
                } else {
                    StateBanner(state: request.state)
                }
                Spacer(minLength: 0)
                if request.host != nil {
                    Button { PermissionCenter.active?.openHost(request) } label: {
                        Text(L("Mở \(request.host?.name ?? "")", "Open \(request.host?.name ?? "")"))
                            .font(.ui(10)).underline().foregroundStyle(PixelPalette.border.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(PixelPalette.dim).frame(width: 2) }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(PixelDialogFrame())
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }
}

// MARK: - Chuyển tab: Pixel tan theo ô vuông, Cassette tua băng

/// Mặt nạ lưới ô vuông hiện dần theo thứ tự giả ngẫu nhiên.
private struct PixelWipeMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        let cell: CGFloat = 18
        var p = Path()
        guard progress < 1 else { return Path(r) }
        let cols = Int(ceil(r.width / cell)), rows = Int(ceil(r.height / cell))
        for i in 0..<cols {
            for j in 0..<rows {
                // Băm cố định từ toạ độ ô → thứ tự hiện không đổi giữa các khung hình.
                var h = UInt64(i &* 73856093) ^ UInt64(j &* 19349663)
                h = (h ^ (h >> 13)) &* 0x5bd1e995
                let order = CGFloat(h % 1000) / 1000
                if order < progress {
                    p.addRect(CGRect(x: r.minX + CGFloat(i) * cell, y: r.minY + CGFloat(j) * cell, width: cell, height: cell))
                }
            }
        }
        return p
    }
}

struct PixelWipe: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(PixelWipeMask(progress: progress))
    }
}

/// Vệt tua băng: nội dung trượt ngang, nhoè, có vạch nhiễu, rồi đứng lại.
struct TapeRewind: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let k = 1 - progress
        content
            .offset(x: -70 * k)
            .blur(radius: 5 * k)
            .overlay {
                if k > 0.02 {
                    Canvas { ctx, size in
                        var rng = SeededRNG(77)
                        for _ in 0..<9 {
                            let y = CGFloat(rng.range(0, Double(size.height)))
                            let w = CGFloat(rng.range(Double(size.width) * 0.3, Double(size.width)))
                            ctx.fill(Path(CGRect(x: CGFloat(rng.range(0, Double(size.width) * 0.5)), y: y, width: w, height: CGFloat(rng.range(1, 3)))),
                                     with: .color(.white.opacity(0.35 * Double(k))))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension AnyTransition {
    /// Chuyển tab theo giao diện; giao diện khác: không đổi gì.
    static var themedTab: AnyTransition {
        if Theme.isPixel {
            return .asymmetric(insertion: .modifier(active: PixelWipe(progress: 0), identity: PixelWipe(progress: 1)),
                               removal: .opacity)
        }
        if Theme.isCassette {
            return .asymmetric(insertion: .modifier(active: TapeRewind(progress: 0), identity: TapeRewind(progress: 1)),
                               removal: .opacity)
        }
        if Theme.isVanGogh {
            return .asymmetric(insertion: .modifier(active: VGBrushWipe(progress: 0), identity: VGBrushWipe(progress: 1)),
                               removal: .opacity)
        }
        return .identity
    }
}
