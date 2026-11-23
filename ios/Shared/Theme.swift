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

/// Máy bay giấy kiểu cổ điển (mũi hướng lên phải): mặt trên đón sáng, mặt dưới trong bóng, khe gấp ở giữa.
/// Toạ độ chuẩn hoá dùng chung cho icon app và hình trên Mac.
enum PlaneShape {
    static let nose = CGPoint(x: 1, y: 0), wing = CGPoint(x: 0, y: 0.44), fold = CGPoint(x: 0.38, y: 0.6)
    static let fold2 = CGPoint(x: 0.45, y: 0.64), tail = CGPoint(x: 0.6, y: 1), flap = CGPoint(x: 0.3, y: 0.66)
}

struct PaperPlane: View {
    var body: some View {
        Canvas { ctx, size in
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * size.width, y: q.y * size.height) }
            func face(_ pts: [CGPoint], _ c: Color) {
                var path = Path(); path.addLines(pts.map(p)); path.closeSubpath(); ctx.fill(path, with: .color(c))
            }
            face([PlaneShape.nose, PlaneShape.wing, PlaneShape.fold], .white)
            face([PlaneShape.wing, PlaneShape.fold, PlaneShape.flap], Color(red: 0.7, green: 0.65, blue: 0.82))
            face([PlaneShape.nose, PlaneShape.fold2, PlaneShape.tail], Color(red: 0.84, green: 0.8, blue: 0.92))
        }
        .aspectRatio(1, contentMode: .fit)
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

/// Máy bay giấy một màu (cùng hình PaperPlane), dùng ở chỗ nhỏ: nút Gửi, vòng tiến độ.
struct PlaneGlyph: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: r.minX + q.x * r.width, y: r.minY + q.y * r.height) }
        var path = Path()
        path.addLines([PlaneShape.nose, PlaneShape.wing, PlaneShape.fold].map(p)); path.closeSubpath()
        path.addLines([PlaneShape.nose, PlaneShape.fold2, PlaneShape.tail].map(p)); path.closeSubpath()
        return path
    }
}
