import AppKit
import CoreImage
import SwiftUI

/// Giao diện: Mặc định hoặc Pixel 8-bit. Đọc thẳng UserDefaults để gọi được từ mọi nơi.
enum Theme: String, CaseIterable, Identifiable {
    case standard, pixel, cassette

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return L("Mặc định", "Default")
        case .pixel: return "Pixel 8-bit"
        case .cassette: return "Cassette"
        }
    }

    static var current: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .standard }
    static var isPixel: Bool { current == .pixel }
    static var isCassette: Bool { current == .cassette }

    /// Đăng ký font VT323 (OFL, đóng gói trong app) cho process.
    static func registerFonts() {
        if let url = Bundle.main.url(forResource: "VT323-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

enum PixelPalette {
    static let border = Color(red: 0.91, green: 0.88, blue: 1.0)
    static let shadow = Color(red: 0.23, green: 0.18, blue: 0.40)
    static let pink = Color(red: 1.0, green: 0.43, blue: 0.66)
    static let dim = Color(red: 0.42, green: 0.37, blue: 0.65)
}

extension Font {
    /// Font giao diện: SF ở theme mặc định, VT323 (pixel, đủ dấu tiếng Việt) ở theme Pixel.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Theme.isPixel ? .custom("VT323", size: size * 1.4) : .system(size: size, weight: weight, design: design)
    }
}

/// Nền nút: capsule (mặc định) hoặc khối vuông có viền + bóng lệch (pixel).
struct ThemedBackground: View {
    let fill: Color

    var body: some View {
        if Theme.isCassette {
            RoundedRectangle(cornerRadius: 4).fill(CassettePalette.key)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.48, green: 0.42, blue: 0.32)))
        } else if Theme.isPixel {
            ZStack {
                Rectangle().fill(PixelPalette.shadow).offset(x: 3, y: 3)
                Rectangle().fill(fill)
                Rectangle().strokeBorder(PixelPalette.border.opacity(0.9), lineWidth: 2)
            }
        } else {
            Capsule().fill(fill)
        }
    }
}

/// Phím vuông pixel (nút ⏮ ⏸ ⏭): nền sáng, bóng lệch.
struct PixelKey: View {
    let fill: Color
    var body: some View {
        ZStack {
            Rectangle().fill(PixelPalette.shadow).offset(x: 3, y: 3)
            Rectangle().fill(fill)
            Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 2)
        }
    }
}

/// Nền tab ở hàng trên cùng.
struct TabBackground: View {
    let selected: Bool

    var body: some View {
        if Theme.isCassette {
            RoundedRectangle(cornerRadius: 3).fill(selected ? CassettePalette.keyDown : CassettePalette.key)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(red: 0.48, green: 0.42, blue: 0.32)))
                .offset(y: selected ? 1.5 : 0)
        } else if Theme.isPixel {
            Rectangle()
                .fill(selected ? PixelPalette.pink : .clear)
                .overlay(Rectangle().strokeBorder(selected ? PixelPalette.pink : PixelPalette.dim, lineWidth: 2))
        } else {
            Capsule().fill(.white.opacity(selected ? 0.14 : 0))
        }
    }
}

/// Thanh tiến trình chia đốt kiểu pixel.
struct PixelSegments: View {
    let ratio: Double
    let accent: Color
    var count = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle().fill(Double(i) / Double(count) < ratio ? accent : .white.opacity(0.18))
            }
        }
    }
}

extension NSImage {
    private static let pixelCache = NSCache<NSImage, NSImage>()

    /// Thu ảnh về size×size ô + giảm màu (posterize) để ra chất 8-bit mà vẫn nhận ra ảnh;
    /// hiển thị kèm .interpolation(.none). 24 ô quá thô với ảnh chụp thật (trông như vỡ ảnh).
    func pixelated(_ size: Int = 48) -> NSImage {
        if let cached = Self.pixelCache.object(forKey: self) { return cached }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var small = NSImage(size: NSSize(width: size, height: size))
        small.addRepresentation(rep)
        // Giảm còn 6 mức/kênh màu: mảng màu phẳng như bảng màu hạn chế của máy 8-bit.
        if let cg = rep.cgImage {
            let poster = CIImage(cgImage: cg).applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6])
            if let out = CIContext().createCGImage(poster, from: poster.extent) {
                small = NSImage(cgImage: out, size: NSSize(width: size, height: size))
            }
        }
        Self.pixelCache.setObject(small, forKey: self)
        return small
    }
}

// MARK: - Icon + menu pixel

/// Icon vẽ theo lưới pixel cho theme Pixel; theme khác dùng SF Symbol.
struct ThemedIcon: View {
    let symbol: String

    static let pixelRows: [String: [String]] = [
        "music.note": ["...11", "..111", "..1.1", "..1..", "111..", "111.."],
        "tray.full.fill": ["11111", "1...1", "11111", "1...1", "11111"],
        "camera.fill": [".111.", "11111", "1...1", "1.1.1", "1...1", "11111"],
        "gearshape.fill": [".1.1.", "11111", "11.11", "11111", ".1.1."],
        "power": ["..1..", "1.1.1", "1...1", "1...1", ".111."],
    ]

    var body: some View {
        if Theme.isPixel, let rows = Self.pixelRows[symbol] {
            PixelShape(rows: rows).fill(ForegroundStyle()).frame(width: 15, height: 15)
        } else {
            Image(systemName: symbol)
        }
    }
}

struct PixelShape: Shape {
    let rows: [String]
    func path(in rect: CGRect) -> Path {
        let cols = rows.map(\.count).max() ?? 1
        let cell = floor(min(rect.width / CGFloat(cols), rect.height / CGFloat(rows.count)))
        let x0 = rect.midX - cell * CGFloat(cols) / 2, y0 = rect.midY - cell * CGFloat(rows.count) / 2
        var p = Path()
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch == "1" {
                p.addRect(CGRect(x: x0 + CGFloat(c) * cell, y: y0 + CGFloat(r) * cell, width: cell, height: cell))
            }
        }
        return p
    }
}

/// Bắt riêng chuột phải: hitTest chỉ nhận khi sự kiện hiện tại là right-click, click trái / kéo đi xuyên qua.
/// Trả về vị trí chuột theo toạ độ .global của SwiftUI (gốc trên-trái của cửa sổ).
struct RightClickCatcher: NSViewRepresentable {
    let action: (CGPoint) -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (CGPoint) -> Void
        init(action: @escaping (CGPoint) -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) {
            let p = event.locationInWindow
            action(CGPoint(x: p.x, y: (window?.contentView?.bounds.height ?? 0) - p.y))
        }
    }
}

/// Menu chuột phải tự vẽ cho theme Pixel / Cassette (NSMenu gốc không đổi được font/kiểu).
struct ThemedMenu: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let action: (() -> Void)?   // nil = vạch ngăn
    }
    let items: [Item]
    let close: () -> Void
    private var hovered = State<UUID?>(initialValue: nil)

    init(items: [Item], close: @escaping () -> Void) {
        self.items = items
        self.close = close
    }

    static let width: CGFloat = 176

    /// Ước lượng chiều cao để kẹp menu trong vùng notch.
    static func height(_ items: [Item]) -> CGFloat {
        let rows = CGFloat(items.filter { $0.action != nil }.count)
        let seps = CGFloat(items.count) - rows
        return Theme.isCassette ? rows * 23 + seps * 9 + 14 : rows * 23 + seps * 9 + 8
    }

    var body: some View {
        let cassette = Theme.isCassette
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                if let action = item.action {
                    let on = hovered.wrappedValue == item.id
                    Text(item.title)
                        .font(cassette ? .hand(15) : .ui(12))
                        .lineLimit(1)
                        .foregroundStyle(cassette ? CassettePalette.ink : (on ? .white : PixelPalette.border))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, cassette ? 2 : 3)
                        .frame(height: 23)
                        .background {
                            if on {
                                if cassette {
                                    // vệt bút dạ quang
                                    RoundedRectangle(cornerRadius: 3).fill(CassettePalette.band.opacity(0.55))
                                        .padding(.vertical, 2).rotationEffect(.degrees(-0.8))
                                } else {
                                    Color(red: 0.18, green: 0.48, blue: 1)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { hovered.wrappedValue = $0 ? item.id : nil }
                        .onTapGesture { close(); action() }
                } else if cassette {
                    Line().stroke(CassettePalette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
                } else {
                    Rectangle().fill(PixelPalette.shadow).frame(height: 3).padding(.vertical, 3).padding(.horizontal, 4)
                }
            }
        }
        .padding(cassette ? 7 : 4)
        .frame(width: Self.width)
        .background { chrome(cassette) }
        .textCase(cassette ? nil : .uppercase)
        .rotationEffect(.degrees(cassette ? -1 : 0))
    }

    @ViewBuilder private func chrome(_ cassette: Bool) -> some View {
        if cassette {
            // tờ giấy note + mẩu băng dính phía trên
            RoundedRectangle(cornerRadius: 3).fill(CassettePalette.label)
                .shadow(color: .black.opacity(0.45), radius: 5, x: 2, y: 4)
                .overlay(alignment: .top) {
                    Rectangle().fill(CassettePalette.note.opacity(0.75))
                        .frame(width: 54, height: 13)
                        .rotationEffect(.degrees(-4))
                        .offset(y: -6)
                }
        } else {
            Color(red: 0.08, green: 0.07, blue: 0.16)
                .overlay(Rectangle().strokeBorder(PixelPalette.border, lineWidth: 3))
                .background(Rectangle().fill(PixelPalette.shadow).offset(x: 4, y: 4))
        }
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}
