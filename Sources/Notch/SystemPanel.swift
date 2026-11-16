import SwiftUI

/// Tab Hệ thống: lưới 3×2 (CPU, bộ nhớ, pin, mạng, ổ đĩa, nhiệt).
/// Chỉ đo khi view đang hiện: `onAppear` giữ, `onDisappear` thả `SystemStats`.
struct SystemPanel: View {
    @ObservedObject var stats = SystemStats.shared

    var body: some View {
        let s = stats.snapshot
        let p = SystemPalette.current
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cpu(s, p); divider(p, vertical: true); memory(s, p); divider(p, vertical: true); battery(s, p)
            }
            divider(p, vertical: false)
            HStack(spacing: 0) {
                network(s, p); divider(p, vertical: true); disk(s, p); divider(p, vertical: true); thermal(s, p)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background {
            if Theme.isVanGogh { RoundedRectangle(cornerRadius: 14).fill(VG.night.opacity(0.62)) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { stats.retain() }
        .onDisappear { stats.release() }
    }

    private func divider(_ p: SystemPalette, vertical: Bool) -> some View {
        Rectangle().fill(p.divider)
            .frame(width: vertical ? (Theme.isPixel ? 2 : 1) : nil, height: vertical ? nil : (Theme.isPixel ? 2 : 1))
            .padding(vertical ? .vertical : .horizontal, 10)
    }

    // MARK: - Ô

    private func cpu(_ s: SystemStats.Snapshot, _ p: SystemPalette) -> some View {
        StatTile(symbol: "cpu", title: "CPU", color: SystemPalette.cpu, palette: p,
                 fraction: s.cpu ?? 0, value: s.cpu.map { "\(Int(($0 * 100).rounded()))" } ?? "--", unit: "%",
                 detail: L("\(s.cores) nhân", "\(s.cores) cores"))
    }

    private func memory(_ s: SystemStats.Snapshot, _ p: SystemPalette) -> some View {
        let f = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        return StatTile(symbol: "memorychip", title: L("Bộ nhớ", "Memory"), color: SystemPalette.memory, palette: p,
                        fraction: f, value: s.memUsed > 0 ? "\(Int((f * 100).rounded()))" : "--", unit: "%",
                        detail: "\(SystemStats.gb(s.memUsed)) / \(SystemStats.gb(s.memTotal)) GB")
    }

    private func battery(_ s: SystemStats.Snapshot, _ p: SystemPalette) -> some View {
        guard let pct = s.batteryPercent else {
            return StatTile(symbol: "powerplug", title: L("Pin", "Battery"), color: SystemPalette.battery, palette: p,
                            fraction: 0, value: "--", unit: nil, detail: L("Không có pin", "No battery"))
        }
        let low = pct <= 20 && !s.batteryOnAC
        let detail: String
        if let w = s.batteryWatts, abs(w) >= 0.1 {
            detail = (w > 0 ? "+" : "−") + String(format: "%.1f W", abs(w))
        } else {
            detail = s.batteryOnAC ? L("Đang cắm sạc", "Plugged in") : "0 W"
        }
        return StatTile(symbol: s.batteryOnAC ? "battery.100.bolt" : "battery.75", title: L("Pin", "Battery"),
                        color: low ? SystemPalette.hot : SystemPalette.battery, palette: p,
                        fraction: Double(pct) / 100, value: "\(pct)", unit: "%", detail: detail)
    }

    private func network(_ s: SystemStats.Snapshot, _ p: SystemPalette) -> some View {
        let down = s.down.map(SystemStats.rate)
        let up = s.up.map(SystemStats.rate)
        // Thang log: 1 KB/s gần như rỗng, 100 MB/s đầy vòng.
        let f = s.down.map { min(1, log10(1 + $0 / 1000) / log10(1 + 100_000)) } ?? 0
        return StatTile(symbol: "arrow.up.arrow.down", title: L("Mạng", "Network"), color: SystemPalette.network, palette: p,
                        fraction: f, value: down?.value ?? "--", unit: down?.unit,
                        detail: up.map { "↑ \($0.value) \($0.unit)" } ?? "↑ --")
    }

    private func disk(_ s: SystemStats.Snapshot, _ p: SystemPalette) -> some View {
        guard let free = s.diskFree, let total = s.diskTotal, total > 0 else {
            return StatTile(symbol: "internaldrive", title: L("Ổ đĩa", "Disk"), color: SystemPalette.disk, palette: p,
                            fraction: 0, value: "--", unit: "%", detail: "")
        }
        let f = 1 - Double(free) / Double(total)
        return StatTile(symbol: "internaldrive", title: L("Ổ đĩa", "Disk"),
                        color: f >= 0.9 ? SystemPalette.hot : SystemPalette.disk, palette: p,
                        fraction: f, value: "\(Int((f * 100).rounded()))", unit: "%",
                        detail: L("\(SystemStats.diskSize(free)) trống", "\(SystemStats.diskSize(free)) free"))
    }

    private func thermal(_ s: SystemStats.Snapshot, _ p: SystemPalette) -> some View {
        let (label, detail, f, color): (String, String, Double, Color) = {
            switch s.thermal {
            case .nominal: return (L("Bình thường", "Normal"), L("Tốc độ tối đa", "Full speed"), 0.25, SystemPalette.cpu)
            case .fair: return (L("Ấm", "Warm"), L("Gần như tối đa", "Nearly full speed"), 0.5, SystemPalette.warm)
            case .serious: return (L("Nóng", "Hot"), L("Đang giảm tốc", "Throttling"), 0.75, SystemPalette.hotter)
            case .critical: return (L("Rất nóng", "Very hot"), L("Giảm tốc mạnh", "Heavy throttling"), 1, SystemPalette.hot)
            @unknown default: return ("--", "", 0, SystemPalette.cpu)
            }
        }()
        return StatTile(symbol: "thermometer.medium", title: L("Nhiệt độ", "Temperature"), color: color, palette: p,
                        fraction: f, value: label, unit: nil, detail: detail, textValue: true)
    }
}

/// Màu chữ / vạch nền theo giao diện; màu từng chỉ số giữ chung để dễ nhận.
struct SystemPalette {
    let text: Color, secondary: Color, track: Color, divider: Color

    static var current: SystemPalette {
        switch Theme.current {
        case .pixel:
            return .init(text: PixelPalette.border, secondary: PixelPalette.border.opacity(0.6),
                         track: PixelPalette.dim.opacity(0.6), divider: PixelPalette.dim.opacity(0.7))
        case .cassette:
            return .init(text: CassettePalette.label, secondary: CassettePalette.line,
                         track: CassettePalette.label.opacity(0.15), divider: CassettePalette.shellEdge)
        case .vangogh:
            return .init(text: VG.cream, secondary: VG.muted, track: VG.cream.opacity(0.18), divider: VG.muted.opacity(0.3))
        case .standard:
            return .init(text: .white, secondary: .white.opacity(0.5), track: .white.opacity(0.14), divider: .white.opacity(0.08))
        }
    }

    static let cpu = Color(red: 0.32, green: 0.85, blue: 0.62)
    static let memory = Color(red: 0.42, green: 0.65, blue: 1.0)
    static let battery = Color(red: 0.68, green: 0.88, blue: 0.32)
    static let network = Color(red: 0.32, green: 0.80, blue: 0.95)
    static let disk = Color(red: 0.70, green: 0.60, blue: 1.0)
    static let warm = Color(red: 0.98, green: 0.80, blue: 0.30)
    static let hotter = Color(red: 1.0, green: 0.58, blue: 0.25)
    static let hot = Color(red: 1.0, green: 0.36, blue: 0.33)
}

private struct StatTile: View {
    let symbol: String
    let title: String
    let color: Color
    let palette: SystemPalette
    let fraction: Double
    let value: String
    let unit: String?
    let detail: String
    var textValue = false

    var body: some View {
        HStack(spacing: 9) {
            TickRing(fraction: fraction, color: color, track: palette.track)
                .overlay { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color) }
                .frame(width: 40, height: 40)
                // Chỉ vòng vạch có animation: chữ số đổi ngay, không mờ chồng số cũ.
                .animation(.easeOut(duration: 0.4), value: fraction)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(10.5, weight: .semibold)).foregroundStyle(palette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.ui(textValue ? 15 : 19, weight: .bold).monospacedDigit())
                        .foregroundStyle(palette.text)
                    if let unit { Text(unit).font(.ui(10, weight: .semibold)).foregroundStyle(palette.secondary) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(detail).font(.ui(10).monospacedDigit()).foregroundStyle(palette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

/// Vòng tròn kiểu vạch: phần đã dùng tô màu, phần còn lại là vạch nền.
private struct TickRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    static let count = 30

    var body: some View {
        let lit = Int((max(0, min(1, fraction)) * Double(Self.count)).rounded())
        let style = StrokeStyle(lineWidth: Theme.isPixel ? 2.6 : 2.2, lineCap: Theme.isPixel ? .butt : .round)
        ZStack {
            Ticks(range: lit..<Self.count, count: Self.count).stroke(track, style: style)
            Ticks(range: 0..<lit, count: Self.count).stroke(color, style: style)
        }
    }
}

private struct Ticks: Shape {
    let range: Range<Int>
    let count: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 - 1.5
        for i in range {
            let a = (Double(i) / Double(count)) * 2 * .pi - .pi / 2
            let dx = cos(a), dy = sin(a)
            p.move(to: CGPoint(x: c.x + dx * r * 0.74, y: c.y + dy * r * 0.74))
            p.addLine(to: CGPoint(x: c.x + dx * r, y: c.y + dy * r))
        }
        return p
    }
}
