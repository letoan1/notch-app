import SwiftUI

/// Màu của Roost Portal: nền mực, giấy ấm, ánh xanh giống khe sáng bên Mac.
enum Theme {
    static let ink = Color(red: 0.05, green: 0.055, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.095, blue: 0.115)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let glow = Color(red: 0.76, green: 0.6, blue: 1)       // tím nhạt, hợp màu Roost
    static let muted = Color.white.opacity(0.55)
    /// Gradient thương hiệu Roost (viền notch trên icon): tím, hồng, cam.
    static let brand = LinearGradient(colors: [Color(red: 0.61, green: 0.48, blue: 1), Color(red: 0.94, green: 0.42, blue: 0.66),
                                               Color(red: 1, green: 0.6, blue: 0.3)], startPoint: .leading, endPoint: .trailing)
}

/// Máy bay giấy gấp 3 mặt (giống icon app): cánh trái đón sáng, sống thân trong bóng, cánh phải.
struct PaperPlane: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
            let nose = p(0.5, 0), lw = p(0, 0.88), rw = p(1, 0.88), tail = p(0.5, 0.72), keel = p(0.56, 0.95)
            func face(_ pts: [CGPoint], _ c: Color) {
                var path = Path(); path.addLines(pts); path.closeSubpath(); ctx.fill(path, with: .color(c))
            }
            face([nose, lw, tail], Color(white: 1))
            face([nose, tail, keel], Color(red: 0.62, green: 0.56, blue: 0.75))
            face([nose, keel, rw], Color(red: 0.87, green: 0.84, blue: 0.93))
        }
        .aspectRatio(0.82, contentMode: .fit)
    }
}

/// Dấu Roost thu nhỏ: notch đen viền gradient trên nền tím, đại diện cho chiếc Mac.
struct NotchMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.26, style: .continuous)
                    .fill(RadialGradient(colors: [Color(red: 0.36, green: 0.25, blue: 0.66), Color(red: 0.12, green: 0.08, blue: 0.25)],
                                         center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: w * 0.7))
                UnevenRoundedRectangle(bottomLeadingRadius: w * 0.09, bottomTrailingRadius: w * 0.09)
                    .fill(.black)
                    .frame(width: w * 0.52, height: h * 0.32)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Theme.brand).frame(height: max(1.5, h * 0.035))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: w * 0.26, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Đường sáng mảnh ở mép trái, thở chậm: luôn nhắc hướng hất về Mac.
/// Chỉ đổi độ mờ (không blur, không shadow động) để không tốn GPU khi cuộn.
struct EdgeRail: View {
    @State private var on = false
    var body: some View {
        LinearGradient(colors: [.clear, Theme.glow.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
            .frame(width: 2.5)
            .opacity(on ? 1 : 0.45)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { on = true } }
    }
}

/// Máy bay giấy nhỏ vẽ bằng Path (dùng ở thẻ Mac và thanh tiến độ).
struct PlaneGlyph: Shape {   // bản một màu, dùng ở chỗ nhỏ
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.15))
        p.addLine(to: CGPoint(x: r.maxX * 0.82, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.15))
        p.closeSubpath()
        return p
    }
}
