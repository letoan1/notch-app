import AppKit
import SwiftUI

/// Giao diện Cassette: trình phát là băng cassette (trục quay theo nhạc), lịch là giấy ghi chú.
enum CassettePalette {
    static let background = Color(red: 0.08, green: 0.07, blue: 0.06)
    static let shell = Color(red: 0.17, green: 0.15, blue: 0.13)
    static let shellEdge = Color(red: 0.29, green: 0.25, blue: 0.22)
    static let plate = Color(red: 0.14, green: 0.12, blue: 0.11)
    static let label = Color(red: 0.94, green: 0.89, blue: 0.80)
    static let band = Color(red: 1.0, green: 0.54, blue: 0.36)
    static let ink = Color(red: 0.17, green: 0.15, blue: 0.13)
    static let line = Color(red: 0.73, green: 0.66, blue: 0.54)
    static let window = Color(red: 0.11, green: 0.09, blue: 0.08)
    static let tape = Color(red: 0.35, green: 0.23, blue: 0.15)
    static let key = Color(red: 0.91, green: 0.86, blue: 0.76)
    static let keyDown = Color(red: 0.79, green: 0.71, blue: 0.56)
    static let note = Color(red: 1.0, green: 0.96, blue: 0.72)
    static let marker = Color(red: 0.89, green: 0.23, blue: 0.23)
    static let faded = Color(red: 0.54, green: 0.48, blue: 0.36)
    static let weekend = Color(red: 0.69, green: 0.48, blue: 0.36)
}

extension Font {
    /// Chữ "viết tay" cho nhãn băng / giấy ghi chú (font có sẵn trên macOS).
    static func hand(_ size: CGFloat) -> Font { .custom("Marker Felt", size: size) }
}

// MARK: - Trình phát

struct CassettePlayerView: View {
    @ObservedObject var media: NowPlaying
    /// Đang tua: vị trí đích (giây) + vị trí lúc bắt đầu kéo.
    private var scrub = State<(target: Double, base: Double)?>(initialValue: nil)

    init(media: NowPlaying) {
        self.media = media
    }

    var body: some View {
        let track = media.track
        let playing = track?.isPlaying == true
        VStack(spacing: 10) {
            // Cập nhật mỗi giây: bộ đếm + lượng băng ở 2 trục.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let position = scrub.wrappedValue?.target ?? track?.position(at: ctx.date) ?? 0
                let ratio = (track?.duration ?? 0) > 0 ? position / track!.duration : 0
                CassetteBody(title: track?.title ?? L("Chưa có băng", "No tape"),
                             artist: track?.artist ?? "",
                             counter: track == nil ? "--:--" : ProgressRow.format(position),
                             total: track.map { ProgressRow.format($0.duration) } ?? "--:--",
                             ratio: ratio, playing: playing,
                             scrubDelta: scrub.wrappedValue.map { $0.target - $0.base })
            }
            .frame(width: 316, height: 150)
            .contentShape(Rectangle())
            .onTapGesture { media.openPlayer() }
            // Kéo ngang thân băng = tua: hết chiều ngang băng ≈ 1/2 bài.
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { v in
                    guard let track, track.duration > 0 else { return }
                    let base = scrub.wrappedValue?.base ?? track.position(at: Date())
                    let target = min(max(base + v.translation.width / 316 * track.duration / 2, 0), track.duration)
                    scrub.wrappedValue = (target, base)
                }
                .onEnded { _ in
                    if let s = scrub.wrappedValue { media.seek(s.target) }
                    scrub.wrappedValue = nil
                })
            .help(L("Bấm để mở app nhạc · kéo ngang để tua", "Click to open the player · drag sideways to seek"))

            HStack(spacing: 8) {
                MechKey(symbol: "backward.fill", pressed: false, action: media.previous)
                MechKey(symbol: playing ? "pause.fill" : "play.fill", pressed: playing, action: media.playPause)
                MechKey(symbol: "forward.fill", pressed: false, action: media.next)
                MechKey(symbol: "eject.fill", pressed: false, action: media.openPlayer)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CassetteBody: View {
    let title: String
    let artist: String
    let counter: String
    let total: String
    let ratio: Double
    let playing: Bool
    /// Đang kéo tua: chênh lệch so với lúc bắt đầu (âm = tua lùi).
    let scrubDelta: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14).fill(CassettePalette.shell)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(CassettePalette.shellEdge, lineWidth: 2))

            // Nhãn băng
            VStack(spacing: 0) {
                HStack {
                    Text("SIDE A")
                    Spacer()
                    Text("\(counter) / \(total)").monospacedDigit()
                }
                .font(.hand(12))
                .foregroundStyle(CassettePalette.ink)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(CassettePalette.band)
                progressMark
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.hand(19)).lineLimit(1)
                    Spacer(minLength: 4)
                    if !artist.isEmpty {
                        Text("— " + artist).font(.hand(12)).opacity(0.7).lineLimit(1)
                    }
                }
                .foregroundStyle(CassettePalette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 1)
                VStack(spacing: 9) {
                    ForEach(0..<3, id: \.self) { _ in Rectangle().fill(CassettePalette.line).frame(height: 1) }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .frame(width: 288, height: 86)
            .background(CassettePalette.label)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .offset(x: 14, y: 10)

            // Cửa sổ băng + dải băng giữa 2 trục
            Capsule().fill(CassettePalette.window).frame(width: 172, height: 38).offset(x: 72, y: 62)
            Rectangle().fill(CassettePalette.tape).frame(width: 80, height: 10).offset(x: 118, y: 76)
            reel(x: 100, wound: 1 - ratio)
            reel(x: 216, wound: ratio)

            BottomPlate().fill(CassettePalette.plate, style: FillStyle(eoFill: true))

            if let delta = scrubDelta {
                // Tờ note to giữa băng khi đang tua: hướng tua + vị trí / tổng.
                HStack(spacing: 6) {
                    Image(systemName: delta < 0 ? "backward.fill" : "forward.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("\(counter) / \(total)").font(.hand(22)).monospacedDigit()
                }
                .foregroundStyle(CassettePalette.ink)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(CassettePalette.note)
                .shadow(color: .black.opacity(0.45), radius: 4, x: 2, y: 3)
                .rotationEffect(.degrees(-2))
                .frame(width: 316, height: 150)
                .offset(y: 8)
                .transition(.opacity)
            }
        }
        .frame(width: 316, height: 150)
        .animation(.easeOut(duration: 0.12), value: scrubDelta == nil)
    }

    /// Vạch bút đỏ chạy theo bài + đầu đọc tam giác: nhìn là biết đang ở đoạn nào.
    private var progressMark: some View {
        GeometryReader { geo in
            let x = geo.size.width * CGFloat(min(max(ratio, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(CassettePalette.line.opacity(0.5)).frame(height: 2)
                Capsule().fill(CassettePalette.marker).frame(width: max(x, 2), height: 3)
                Triangle().fill(CassettePalette.ink)
                    .frame(width: 7, height: 6)
                    .offset(x: x - 3.5, y: -5)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 8)
    }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }

    /// Trục băng: đĩa băng nâu to/nhỏ theo lượng băng đang cuộn + bánh răng quay khi phát.
    private func reel(x: CGFloat, wound: Double) -> some View {
        let r = 10 + 7 * CGFloat(min(max(wound, 0), 1))
        return ZStack {
            Circle().fill(Color(red: 0.23, green: 0.2, blue: 0.17)).frame(width: 36, height: 36)
            Circle().fill(CassettePalette.tape).frame(width: r * 2, height: r * 2)
            ReelHub(spinning: playing).frame(width: 20, height: 20)
        }
        .position(x: x, y: 81)
    }
}

/// Đế dưới hình thang của vỏ băng, 2 lỗ trục (eoFill).
private struct BottomPlate: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 62, y: rect.maxY))
        p.addLine(to: CGPoint(x: 80, y: rect.maxY - 36))
        p.addLine(to: CGPoint(x: 236, y: rect.maxY - 36))
        p.addLine(to: CGPoint(x: 254, y: rect.maxY))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 96, y: rect.maxY - 20, width: 8, height: 8))
        p.addEllipse(in: CGRect(x: 212, y: rect.maxY - 20, width: 8, height: 8))
        return p
    }
}

/// Bánh răng trục băng: quay bằng Core Animation (không dựng lại view mỗi frame).
struct ReelHub: NSViewRepresentable {
    let spinning: Bool
    func makeNSView(context: Context) -> ReelHubView { ReelHubView() }
    func updateNSView(_ view: ReelHubView, context: Context) { view.setSpinning(spinning) }
}

final class ReelHubView: NSView {
    private let spinner = CALayer()
    private let disc = CAShapeLayer()
    private let spokes = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        disc.fillColor = NSColor(red: 0.94, green: 0.89, blue: 0.80, alpha: 1).cgColor
        spokes.strokeColor = NSColor(red: 0.17, green: 0.15, blue: 0.13, alpha: 1).cgColor
        spokes.lineWidth = 2.4
        spokes.lineCap = .round
        spinner.addSublayer(disc)
        spinner.addSublayer(spokes)
        layer?.addSublayer(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.frame = bounds
        disc.frame = bounds
        spokes.frame = bounds
        disc.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let rr = min(bounds.width, bounds.height) / 2
        let path = CGMutablePath()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            path.move(to: CGPoint(x: c.x + rr * 0.3 * cos(a), y: c.y + rr * 0.3 * sin(a)))
            path.addLine(to: CGPoint(x: c.x + rr * 0.75 * cos(a), y: c.y + rr * 0.75 * sin(a)))
        }
        spokes.path = path
        CATransaction.commit()
    }

    func setSpinning(_ on: Bool) {
        if on, spinner.animation(forKey: "spin") == nil {
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0
            anim.toValue = -2 * Double.pi
            anim.duration = 2.4
            anim.repeatCount = .infinity
            spinner.add(anim, forKey: "spin")
        } else if !on {
            spinner.removeAnimation(forKey: "spin")
        }
    }
}

/// Phím cơ: phím đang bật lún xuống.
private struct MechKey: View {
    let symbol: String
    let pressed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CassettePalette.ink)
                .frame(width: 70, height: pressed ? 31 : 35)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(pressed ? CassettePalette.keyDown : CassettePalette.key)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.48, green: 0.42, blue: 0.32)))
                )
                .offset(y: pressed ? 2 : 0)
                .frame(height: 37, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lịch giấy ghi chú

struct NoteCalendar: View {
    @ObservedObject var calendar: CalendarStore

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Lang.locale
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(calendar.monthTitle).font(.hand(16)).foregroundStyle(CassettePalette.ink).lineLimit(1)
                Spacer(minLength: 2)
                Button { calendar.shiftWeek(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Button { calendar.shiftWeek(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(CassettePalette.ink.opacity(0.7))

            HStack(spacing: 0) {
                ForEach(calendar.weekDays, id: \.self) { day in
                    dayCell(day)
                }
            }

            if calendar.access == .granted {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        if calendar.selectedEvents.isEmpty {
                            Text(L("Trống trơn ✌︎", "Nothing planned ✌︎"))
                                .font(.hand(13)).foregroundStyle(CassettePalette.ink.opacity(0.6))
                        }
                        ForEach(calendar.selectedEvents) { item in
                            HStack(spacing: 6) {
                                Text("• \(timeLabel(item)) \(item.title)")
                                    .font(.hand(13)).foregroundStyle(CassettePalette.ink).lineLimit(1)
                                Spacer(minLength: 2)
                                if let meeting = item.meeting { JoinButton(meeting: meeting, prominent: true) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button(L("Bấm để cho phép đọc lịch", "Click to allow calendar access")) {
                    if calendar.access == .notDetermined { calendar.requestAccess() } else { calendar.openPrivacySettings() }
                }
                .font(.hand(13))
                .foregroundStyle(CassettePalette.ink)
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 226, height: 186, alignment: .topLeading)
        .background(Rectangle().fill(CassettePalette.note).shadow(color: .black.opacity(0.35), radius: 6, x: 3, y: 4))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(red: 0.95, green: 0.9, blue: 0.79).opacity(0.85))
                .frame(width: 56, height: 14).rotationEffect(.degrees(4)).offset(y: -7)
        }
        .rotationEffect(.degrees(-2.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dayCell(_ day: Date) -> some View {
        let weekday = cal.component(.weekday, from: day)
        let weekend = cal.isDateInWeekend(day)
        let selected = day == calendar.selectedDay
        let isToday = cal.isDateInToday(day)
        return Button { calendar.selectedDay = day } label: {
            VStack(spacing: 1) {
                Text(cal.veryShortWeekdaySymbols[weekday - 1])
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(CassettePalette.faded)
                Text("\(cal.component(.day, from: day))")
                    .font(.hand(isToday ? 16 : 14))
                    .foregroundStyle(weekend ? CassettePalette.weekend : CassettePalette.ink)
                    .frame(width: 26, height: 22)
                    .overlay(
                        Ellipse().stroke(CassettePalette.marker, lineWidth: 2)
                            .rotationEffect(.degrees(-8))
                            .opacity(selected ? 1 : 0)
                    )
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timeLabel(_ item: CalendarStore.Item) -> String {
        if item.allDay { return L("cả ngày", "all day") }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: item.start)
    }
}
