import AppKit
import CoreImage

extension NSImage {
    /// Màu trung bình của ảnh, đẩy sáng/bão hoà lên để nổi trên nền đen.
    func accentColor() -> NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        guard let output = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ])?.outputImage else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)

        let avg = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                          blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Ảnh gần như xám: dùng trắng thay vì một màu xám đục.
        if s < 0.12 { return .white }
        return NSColor(hue: h, saturation: min(max(s * 1.4, 0.45), 0.85),
                       brightness: max(b, 0.85), alpha: 1)
    }
}
