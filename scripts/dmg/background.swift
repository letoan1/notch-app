// Vẽ ảnh nền cửa sổ .dmg: hai ô icon, mũi tên "kéo sang", dòng nhắc hướng dẫn.
//   swift scripts/dmg/background.swift <thư mục ra>   → bg.png (1x) và bg@2x.png
// Kích thước khớp với layout.sh (cửa sổ 640x440, icon ở x=170 và x=470, y=165; file hướng dẫn ở x=320, y=345).
import AppKit

let W: CGFloat = 640, H: CGFloat = 440
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    // flipped: true để chữ không bị lộn ngược khi lật trục bên dưới.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, flipped: true)
    // Toạ độ AppKit gốc ở dưới; đổi sang gốc trên cho dễ khớp với Finder.
    let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: H); flip.scaleX(by: 1, yBy: -1); flip.concat()

    NSColor(srgbRed: 0.969, green: 0.957, blue: 0.937, alpha: 1).setFill()   // #f7f4ef, cùng nền trang web
    NSRect(x: 0, y: 0, width: W, height: H).fill()

    // Hai ô mờ sau icon.
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.045).setFill()
    for x in [170.0, 470.0] {
        NSBezierPath(roundedRect: NSRect(x: x - 76, y: 165 - 70, width: 152, height: 162), xRadius: 26, yRadius: 26).fill()
    }

    // Mũi tên nét đứt từ app sang Applications.
    let accent = NSColor(srgbRed: 0.486, green: 0.361, blue: 1, alpha: 1)        // tím của trang web
    accent.setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 268, y: 165)); line.line(to: NSPoint(x: 362, y: 165))
    line.lineWidth = 3; line.lineCapStyle = .round
    line.setLineDash([2, 9], count: 2, phase: 0)
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 360, y: 153)); head.line(to: NSPoint(x: 374, y: 165)); head.line(to: NSPoint(x: 360, y: 177))
    head.lineWidth = 3; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.stroke()

    func text(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: p]
        (s as NSString).draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.5), withAttributes: a)
    }
    let ink = NSColor(srgbRed: 0.11, green: 0.098, blue: 0.137, alpha: 1)
    text("Kéo Roost vào Applications", y: 34, size: 20, weight: .bold, color: ink)
    text("Drag Roost to Applications", y: 62, size: 13, weight: .medium, color: ink.withAlphaComponent(0.5))
    text("Lần đầu mở bị macOS chặn? Mở file hướng dẫn bên dưới.", y: 268, size: 12, weight: .medium, color: ink.withAlphaComponent(0.55))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out + "/bg.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: out + "/bg@2x.png"))
