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
