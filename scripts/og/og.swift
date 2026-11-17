// Ảnh xem trước khi chia sẻ link (Open Graph, 1200x630): notch đang mở có bài hát + thẻ Claude, tiêu đề, dòng mô tả.
//   swift scripts/og/og.swift vi site/assets/og.png
//   swift scripts/og/og.swift en site/assets/og-en.png
import AppKit

let args = CommandLine.arguments
let en = args.count > 1 && args[1] == "en"
let out = args.count > 2 ? args[2] : "og.png"
let W: CGFloat = 1200, H: CGFloat = 630
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let ink = rgb(0x111114), ink2 = rgb(0x55555e), accent = rgb(0xe8541c)

func text(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, align: NSTextAlignment = .left) {
    let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
    (s as NSString).draw(in: r, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}
func width(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, flipped: true)
let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: H); flip.scaleX(by: 1, yBy: -1); flip.concat()

rgb(0xfbfaf8).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

// Notch mở: khối đen dính mép trên, bo hai góc dưới.
let notch = NSRect(x: 290, y: -40, width: 620, height: 210)
rgb(0x000000).setFill(); NSBezierPath(roundedRect: notch, xRadius: 40, yRadius: 40).fill()
// Ảnh bìa + tên bài.
let art = NSRect(x: 326, y: 52, width: 80, height: 80)
NSGradient(starting: rgb(0xff7a3d), ending: rgb(0xb93a12))!.draw(in: NSBezierPath(roundedRect: art, xRadius: 14, yRadius: 14), angle: -60)
text("Lặng", .systemFont(ofSize: 28, weight: .bold), .white, in: NSRect(x: 424, y: 58, width: 200, height: 36))
text("Rhymastic", .systemFont(ofSize: 21, weight: .medium), rgb(0xffffff, 0.55), in: NSRect(x: 424, y: 96, width: 200, height: 28))
// Phổ âm thanh.
accent.setFill()
for (i, h) in [18.0, 34, 24, 40, 16].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 590 + CGFloat(i) * 11, y: 92 - h / 2, width: 6, height: h), xRadius: 3, yRadius: 3).fill()
}
// Thẻ Claude đang hỏi.
let chip = NSRect(x: 672, y: 66, width: 206, height: 52)
rgb(0xffffff, 0.09).setFill(); NSBezierPath(roundedRect: chip, xRadius: 26, yRadius: 26).fill()
rgb(0xd97857).setFill(); NSBezierPath(ovalIn: NSRect(x: 690, y: 84, width: 16, height: 16)).fill()
text(en ? "Claude asks" : "Claude đang hỏi", .systemFont(ofSize: 19, weight: .semibold), .white,
     in: NSRect(x: 716, y: 79, width: 156, height: 26))

// Tiêu đề và mô tả.
text(en ? "Small notch. Room for everything." : "Notch nhỏ. Việc gì cũng có chỗ.",
     .systemFont(ofSize: 66, weight: .heavy), ink, in: NSRect(x: 40, y: 236, width: W - 80, height: 90), align: .center)
text(en ? "Music, calendar, a file tray and Claude Code, right on your MacBook notch."
        : "Nhạc, lịch, khay file và Claude Code ngay trên notch MacBook.",
     .systemFont(ofSize: 29, weight: .regular), ink2, in: NSRect(x: 40, y: 346, width: W - 80, height: 40), align: .center)

// Dòng cuối: icon + tên + thông tin.
let name = "Roost", nameFont = NSFont.systemFont(ofSize: 34, weight: .bold)
let info = en ? "Free & open source  ·  macOS 14+" : "Miễn phí, mã nguồn mở  ·  macOS 14+"
let infoFont = NSFont.systemFont(ofSize: 24, weight: .medium)
let total = 64 + 16 + width(name, nameFont) + 28 + width(info, infoFont)
var x = (W - total) / 2
if let icon = NSImage(contentsOfFile: "site/assets/icon.png") {
    icon.draw(in: NSRect(x: x, y: 470, width: 64, height: 64), from: .zero, operation: .sourceOver, fraction: 1,
              respectFlipped: true, hints: nil)
}
x += 80
text(name, nameFont, ink, in: NSRect(x: x, y: 480, width: 200, height: 44)); x += width(name, nameFont) + 28
text(info, infoFont, ink2, in: NSRect(x: x, y: 487, width: 600, height: 34))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("→ \(out)")
