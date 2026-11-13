import SwiftUI

/// Mép trên phẳng với 2 góc lõm ("tai"), mép dưới bo tròn như notch thật.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Pixel 8-bit: đáy bo kiểu bậc thang, tai trên vuông.
    var pixel = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if pixel { return Self.stairPath(in: rect, inset: topRadius) }
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }

    private static func stairPath(in rect: CGRect, inset: CGFloat) -> Path {
        let step: CGFloat = 6, n = 3
        let l = rect.minX + inset, r = rect.maxX - inset, b = rect.maxY
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: r, y: rect.minY))
        p.addLine(to: CGPoint(x: r, y: b - CGFloat(n) * step))
        for k in 0..<n {
            p.addLine(to: CGPoint(x: r - CGFloat(k) * step, y: b - CGFloat(n - k - 1) * step))
            p.addLine(to: CGPoint(x: r - CGFloat(k + 1) * step, y: b - CGFloat(n - k - 1) * step))
        }
        p.addLine(to: CGPoint(x: l + CGFloat(n) * step, y: b))
        for k in 0..<n {
            p.addLine(to: CGPoint(x: l + CGFloat(n - k) * step, y: b - CGFloat(k + 1) * step))
            p.addLine(to: CGPoint(x: l + CGFloat(n - k - 1) * step, y: b - CGFloat(k + 1) * step))
        }
        p.addLine(to: CGPoint(x: l, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
