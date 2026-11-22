import SwiftUI

/// Màu của Roost Portal: nền mực, giấy ấm, ánh xanh giống khe sáng bên Mac.
enum Theme {
    static let ink = Color(red: 0.05, green: 0.055, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.095, blue: 0.115)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let glow = Color(red: 0.5, green: 0.83, blue: 1)
    static let muted = Color.white.opacity(0.55)
}

/// Đường sáng mảnh ở mép trái, thở chậm: luôn nhắc hướng hất về Mac.
struct EdgeRail: View {
    @State private var on = false
    var body: some View {
        LinearGradient(colors: [.clear, Theme.glow.opacity(on ? 0.9 : 0.35), .clear], startPoint: .top, endPoint: .bottom)
            .frame(width: 3)
            .blur(radius: 1.5)
            .shadow(color: Theme.glow.opacity(on ? 0.8 : 0.3), radius: 8)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever()) { on = true } }
    }
}

/// Máy bay giấy nhỏ vẽ bằng Path (dùng ở thẻ Mac và thanh tiến độ).
struct PlaneGlyph: Shape {
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
