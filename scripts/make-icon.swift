// Vẽ icon app (1 lần): swiftc scripts/make-icon.swift -o /tmp/mkicon && /tmp/mkicon Resources/AppIcon.png
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Khung squircle theo lưới icon macOS: thân 824px, lề 100px.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(calibratedRed: 0.33, green: 0.40, blue: 0.96, alpha: 1),
           ending: NSColor(calibratedRed: 0.66, green: 0.30, blue: 0.86, alpha: 1))!
    .draw(in: squircle, angle: -60)

// "Tai thỏ" đen dính mép trên, bo góc dưới, bên trong có ảnh bìa + sóng nhạc.
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
let nw: CGFloat = 470, nh: CGFloat = 160
let nx = body.midX - nw / 2, ny = body.maxY - nh
NSColor.black.setFill()
NSBezierPath(roundedRect: CGRect(x: nx, y: ny, width: nw, height: nh + 100), xRadius: 72, yRadius: 72).fill()

NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.35, alpha: 1),
           ending: NSColor(calibratedRed: 0.98, green: 0.40, blue: 0.40, alpha: 1))!
    .draw(in: NSBezierPath(roundedRect: CGRect(x: nx + 48, y: ny + 42, width: 78, height: 78), xRadius: 18, yRadius: 18),
          angle: -45)

NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.48, alpha: 1).setFill()
let heights: [CGFloat] = [36, 72, 52, 28]
let barW: CGFloat = 13, gap: CGFloat = 9
let barsX = nx + nw - 52 - (barW * 4 + gap * 3)
for (i, h) in heights.enumerated() {
    let rect = CGRect(x: barsX + CGFloat(i) * (barW + gap), y: ny + 81 - h / 2, width: barW, height: h)
    NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("→ \(out)")
