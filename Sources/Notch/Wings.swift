import SwiftUI

/// Nội dung một bên cánh notch lúc thu gọn, đã quyết theo Cài đặt + trạng thái hiện tại.
enum WingContent: Equatable {
    case artwork, equalizer, battery, clock, coffee, claudeUsage
    case meeting(start: Date, end: Date, video: Bool)

    func width(height: CGFloat) -> CGFloat {
        switch self {
        case .artwork, .equalizer: return height
        case .clock: return 46
        case .claudeUsage: return 52
        case .coffee: return 26
        case .battery: return 58
        case .meeting: return 64
        }
    }
}

/// Hai cánh lúc thu gọn. Hai bên luôn rộng bằng nhau để notch vẫn nằm giữa camera.
struct WingLayout: Equatable {
    var left: WingContent?
    var right: WingContent?
    /// Bề rộng mỗi bên; 0 = không có cánh.
    var width: CGFloat

    /// Chỉ hiện cuộc họp bắt đầu trong vòng 2 giờ tới (hoặc đang diễn ra).
    static let meetingWindow: TimeInterval = 2 * 3600

    @MainActor
    static func resolve(settings: SettingsStore, hasTrack: Bool, calendar: CalendarStore,
                        battery: Int?, height: CGFloat) -> WingLayout {
        func content(_ item: SettingsStore.WingItem, auto: WingContent) -> WingContent? {
            switch item {
            case .auto: return hasTrack ? auto : nil
            case .artwork: return hasTrack ? .artwork : nil
            case .equalizer: return hasTrack ? .equalizer : nil
            case .battery: return battery == nil ? nil : .battery
            case .clock: return .clock
            case .claude: return ClaudeUsage.shared.hasData ? .claudeUsage : nil
            case .none: return nil
            case .meeting:
                guard calendar.weekOffset == 0 else { return nil }
                let now = Date()
                guard let e = calendar.windowEvents.first(where: {
                    !$0.allDay && $0.end > now && $0.start.timeIntervalSince(now) <= meetingWindow
                }) else { return nil }
                return .meeting(start: e.start, end: e.end, video: e.meeting != nil)
            }
        }
        var left = content(settings.leftWing, auto: .artwork)
        var right = content(settings.rightWing, auto: .equalizer)
        // Đang giữ máy thức: ly cà phê nhỏ ở bên còn trống (hết chỗ thì thay bên phải).
        if KeepAwake.shared.active {
            if left == nil { left = .coffee } else { right = .coffee }
        }
        let width = [left, right].compactMap { $0?.width(height: height) }.max() ?? 0
        return WingLayout(left: left, right: right, width: width)
    }
}

/// Vẽ hai cánh theo WingLayout. Mặc định (Tự động) trông y như bản cũ: ảnh bìa | sóng nhạc.
struct CollapsedWings: View {
    @ObservedObject var media: NowPlaying
    @ObservedObject var system = SystemMonitor.shared
    let layout: WingLayout
    let height: CGFloat
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            side(layout.left).frame(width: layout.width, height: height)
            Spacer(minLength: 0)
            side(layout.right).frame(width: layout.width, height: height)
        }
    }

    @ViewBuilder private func side(_ content: WingContent?) -> some View {
        switch content {
        case .artwork?:
            Group {
                if Theme.isCassette {
                    MiniTape(band: CassettePalette.band, name: "")
                        .frame(width: height - 8, height: (height - 8) * 0.66)
                } else if Theme.isVanGogh {
                    // Bản sơn dầu nếu đã vẽ xong, viền vàng như khung tranh nhỏ.
                    Artwork(image: media.artwork.map { OilPaint.cached($0) ?? $0 }, corner: 5)
                        .frame(width: height - 13, height: height - 13)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(VG.yellow, lineWidth: 1.6))
                        .matchedGeometryEffect(id: "artwork", in: ns)
                } else {
                    Artwork(image: media.artwork, corner: 6)
                        .frame(width: height - 12, height: height - 12)
                        .matchedGeometryEffect(id: "artwork", in: ns)
                }
            }
        case .equalizer?:
            Group {
                if Theme.isCassette {
                    HStack(spacing: 3) {
                        MiniReel(spinning: media.isPlaying).frame(width: 13, height: 13)
                        MiniReel(spinning: media.isPlaying).frame(width: 13, height: 13)
                    }
                } else if media.isPlaying {
                    EqualizerBars(active: true, color: Theme.isVanGogh ? VG.yellow : media.accent)
                        .frame(width: height, height: height)
                } else {
                    // Tạm dừng: nốt nhạc đứng yên thay cho sóng.
                    Image(systemName: "music.note")
                        .font(.ui(9, weight: .semibold))
                        .foregroundStyle((Theme.isVanGogh ? VG.yellow : media.accent).opacity(0.85))
                }
            }
            .transition(.opacity)
        case .clock?:
            // Cập nhật mỗi phút, không có timer theo giây.
            TimelineView(.everyMinute) { ctx in
                Text(Self.clock.string(from: ctx.date))
                    .font(.ui(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.isVanGogh ? VG.cream : .white.opacity(0.85))
            }
        case .battery?:
            if let percent = system.batteryPercent {
                let color: Color = system.batteryCharging ? Color(red: 0.30, green: 0.85, blue: 0.40)
                    : percent <= 20 ? Color(red: 1, green: 0.35, blue: 0.3) : Theme.isVanGogh ? VG.cream : .white.opacity(0.85)
                HStack(spacing: 4) {
                    Text("\(percent)%")
                        .font(.ui(11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color)
                    MiniBattery(level: Double(percent) / 100, color: color)
                }
            }
        case let .meeting(start, end, video)?:
            TimelineView(.everyMinute) { ctx in
                HStack(spacing: 4) {
                    Image(systemName: video ? "video.fill" : "calendar")
                        .font(.system(size: 9, weight: .semibold))
                    Text(Self.meetingText(start: start, end: end, now: ctx.date))
                        .font(.ui(11, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.isVanGogh ? VG.yellow : Color(red: 0.45, green: 0.75, blue: 1))
            }
        case .claudeUsage?:
            ClaudeUsageWing()
        case .coffee?:
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KeepAwakeButton.activeColor)
        case nil:
            Color.clear
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "12p" khi còn dưới 1 giờ, "9:30" khi xa hơn, "Bây giờ" khi đã bắt đầu.
    static func meetingText(start: Date, end: Date, now: Date) -> String {
        if now >= start { return L("Bây giờ", "Now") }
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        if minutes < 60 { return L("\(minutes)p", "\(minutes)m") }
        return clock.string(from: start)
    }
}

/// Biểu tượng pin nhỏ cho cánh notch.
private struct MiniBattery: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                    .frame(width: 18, height: 9)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: max(1.5, 15 * level), height: 6)
                    .padding(.leading, 1.5)
            }
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 3)
        }
    }
}
