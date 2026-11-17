import AppKit

extension NSImage {
    /// Màu trung bình của ảnh, đẩy sáng/bão hoà lên để nổi trên nền đen.
    func accentColor() -> NSColor? {
        // Thu ảnh về 8x8 bằng CoreGraphics rồi lấy trung bình. Không dùng CIContext: mỗi lần tạo là nạp Metal
        // và bộ đệm Core Image (~8 MB) mà Core Image giữ lại.
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }
        var sum = [0, 0, 0]
        for i in stride(from: 0, to: px.count, by: 4) { for c in 0..<3 { sum[c] += Int(px[i + c]) } }
        let count = CGFloat(n * n * 255)

        let avg = NSColor(srgbRed: CGFloat(sum[0]) / count, green: CGFloat(sum[1]) / count,
                          blue: CGFloat(sum[2]) / count, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Ảnh gần như xám: dùng trắng thay vì một màu xám đục.
        if s < 0.12 { return .white }
        return NSColor(hue: h, saturation: min(max(s * 1.4, 0.45), 0.85),
                       brightness: max(b, 0.85), alpha: 1)
    }
}
