import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Giao diện Cassette cho các tab còn lại: kệ băng (khay), khung ngắm máy quay (gương),
/// phiếu đánh máy + con dấu (Claude xin quyền), bảng ghim (Claude hỏi).

extension Font {
    static func typewriter(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "AmericanTypewriter-Bold" : "American Typewriter", size: size)
    }
}

/// Màu dải nhãn băng theo loại file.
func fileTint(_ url: URL) -> Color {
    if url.hasDirectoryPath { return Color(red: 0.39, green: 0.82, blue: 1.0) }
    guard let type = UTType(filenameExtension: url.pathExtension) else { return Color(red: 0.43, green: 0.48, blue: 0.85) }
    if type.conforms(to: .pdf) { return Color(red: 1.0, green: 0.35, blue: 0.32) }
    if type.conforms(to: .image) { return Color(red: 0.19, green: 0.69, blue: 0.35) }
    if type.conforms(to: .movie) { return Color(red: 0.66, green: 0.33, blue: 0.97) }
    if type.conforms(to: .audio) { return Color(red: 1.0, green: 0.31, blue: 0.55) }
    if type.conforms(to: .archive) { return Color(red: 0.56, green: 0.56, blue: 0.58) }
    if type.conforms(to: .sourceCode) || type.conforms(to: .text) { return Color(red: 0.04, green: 0.52, blue: 1.0) }
    return Color(red: 1.0, green: 0.62, blue: 0.04)
}

// MARK: - Băng mini (khay + notch thu gọn)

struct MiniTape: View {
    let band: Color
    let name: String

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: h * 0.09).fill(CassettePalette.shell)
                    .overlay(RoundedRectangle(cornerRadius: h * 0.09).stroke(CassettePalette.shellEdge, lineWidth: 1.5))
                VStack(spacing: 0) {
                    band.frame(height: h * 0.14)
                    if !name.isEmpty {
                        Text(name)
                            .font(.hand(max(8, h * 0.15)))
                            .foregroundStyle(CassettePalette.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 4)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 2)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: w - h * 0.18, height: h * 0.5)
                .background(CassettePalette.label)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(.top, h * 0.08)
                Capsule().fill(CassettePalette.window)
                    .frame(width: w * 0.5, height: h * 0.22)
                    .offset(y: h * 0.5)
                HStack(spacing: w * 0.2) { reelDot(h); reelDot(h) }
                    .offset(y: h * 0.525)
            }
        }
    }

    private func reelDot(_ h: CGFloat) -> some View {
        Circle().fill(CassettePalette.label).frame(width: h * 0.17, height: h * 0.17)
            .overlay(Circle().fill(CassettePalette.ink).frame(width: h * 0.06, height: h * 0.06))
    }
}

/// Trục băng nhỏ quay theo nhạc (cánh notch thu gọn).
struct MiniReel: View {
    let spinning: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.23, green: 0.2, blue: 0.17))
            ReelHub(spinning: spinning).padding(2)
        }
    }
}

// MARK: - Khay → kệ băng

struct CassetteTrayView: View {
    @ObservedObject var tray: TrayStore
    let targeted: Bool

    var body: some View {
        HStack(spacing: 14) {
            if !tray.files.isEmpty {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tray.files, id: \.self) { url in
                                MiniTapeTile(url: url) { tray.remove(url) }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 6)
                    }
                    Rectangle().fill(Color(red: 0.42, green: 0.29, blue: 0.18)).frame(height: 8)
                    Rectangle().fill(Color(red: 0.29, green: 0.2, blue: 0.13)).frame(height: 4)
                }
            }
            TapeSlot(targeted: targeted, wide: tray.files.isEmpty)
                .frame(width: tray.files.isEmpty ? nil : 170)
                .contextMenu {
                    if !tray.files.isEmpty {
                        Button(L("AirDrop tất cả", "AirDrop all")) {
                            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: tray.files)
                        }
                        Divider()
                        Button(L("Xoá hết khay (file gốc không bị xoá)", "Clear tray (files stay on disk)")) { tray.clear() }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .onAppear { tray.prune() }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct MiniTapeTile: View {
    let url: URL
    let remove: () -> Void
    private var hover = State(initialValue: false)

    init(url: URL, remove: @escaping () -> Void) {
        self.url = url
        self.remove = remove
    }

    var body: some View {
        MiniTape(band: fileTint(url), name: url.lastPathComponent)
            .frame(width: 112, height: 76)
            .overlay(alignment: .topTrailing) {
                if hover.wrappedValue {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(CassettePalette.label, CassettePalette.ink)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
            .scaleEffect(hover.wrappedValue ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
            .contentShape(Rectangle())
            .onHover { hover.wrappedValue = $0 }
            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            .onDrag { NSItemProvider(object: url as NSURL) }
            .contextMenu { ShareMenu(url: url, remove: remove) }
            .help(url.path)
    }
}

private struct TapeSlot: View {
    let targeted: Bool
    let wide: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.14, green: 0.12, blue: 0.11))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(targeted ? CassettePalette.band : CassettePalette.shellEdge, lineWidth: 2))
            .overlay(
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black).frame(height: 8).padding(.horizontal, 18)
                    Image(systemName: "arrow.down").font(.system(size: 18, weight: .bold))
                    Text(wide ? L("Nhét băng vào đây · kéo file lên notch", "Slot a tape in · drag files onto the notch")
                              : L("Nhét băng\nvào đây", "Slot a\ntape in"))
                        .font(.hand(15))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(CassettePalette.key.opacity(targeted ? 1 : 0.85))
                .padding(.top, 10)
            )
            .scaleEffect(targeted ? 1.03 : 1)
    }
}

// MARK: - Gương → khung ngắm máy quay

struct CassetteMirrorView: View {
    @ObservedObject var camera: CameraMirror
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var edge = EdgeLight.shared
    private var openedAt = State(initialValue: Date())

    init(camera: CameraMirror, calendar: CalendarStore) {
        self.camera = camera
        self.calendar = calendar
    }

    var body: some View {
        HStack(spacing: 16) {
            viewfinder.frame(width: 300)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Sẵn sàng họp?", "Ready for the call?")).font(.hand(20)).foregroundStyle(CassettePalette.key)
                meetingNote
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    KeyButton(title: camera.mirrored ? L("⇄ Lật: gương", "⇄ Flip: mirror") : L("⇄ Lật: thật", "⇄ Flip: true"),
                              pressed: false, lit: false) { camera.mirrored.toggle() }
                    KeyButton(title: edge.level.title, pressed: edge.isOn, lit: edge.isOn) { edge.cycle() }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear {
            openedAt.wrappedValue = Date()
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.14, green: 0.12, blue: 0.11))
            Group {
                switch camera.access {
                case .granted:
                    CameraPreview(session: camera.session, cornerRadius: 6, mirrored: camera.mirrored)
                case .notDetermined:
                    placeholder(L("Bấm để bật máy quay", "Click to turn on the camera"), action: camera.requestAccess)
                case .denied:
                    placeholder(L("Mở Cài đặt để cấp quyền camera", "Open Settings to allow camera access"),
                                action: camera.openPrivacySettings)
                }
            }
            .padding(6)
            // Lớp chữ máy quay: REC nhấp nháy, mã thời gian từ lúc mở tab, ngày kiểu VHS.
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let elapsed = Int(ctx.date.timeIntervalSince(openedAt.wrappedValue))
                let blinkOn = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                ZStack {
                    ViewfinderCorners().stroke(Color.white.opacity(0.85), lineWidth: 2.2).padding(16)
                    VStack {
                        HStack {
                            HStack(spacing: 5) {
                                Circle().fill(CassettePalette.marker).frame(width: 10, height: 10)
                                Text("REC").font(.typewriter(13, bold: true)).foregroundStyle(.white)
                            }
                            .opacity(blinkOn ? 1 : 0)
                            Spacer()
                            Text(String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
                                .font(.typewriter(13)).foregroundStyle(.white).monospacedDigit()
                        }
                        Spacer()
                        HStack {
                            Text(Self.vhsDate).font(.typewriter(13, bold: true))
                                .foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.28))
                            Spacer()
                            Image(systemName: "battery.100").font(.system(size: 14)).foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private static var vhsDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d yyyy"
        return f.string(from: Date()).uppercased()
    }

    private func placeholder(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.23, green: 0.2, blue: 0.17))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill").font(.system(size: 22))
                        Text(text).font(.hand(14)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(CassettePalette.key)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var meetingNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let next = calendar.nextEvent {
                HStack(spacing: 6) {
                    Text("• \(Self.hm(next.start)) \(next.title)").font(.hand(14)).lineLimit(1)
                    Spacer(minLength: 2)
                    if let meeting = next.meeting { JoinButton(meeting: meeting, prominent: true) }
                }
                Text(Self.untilText(next)).font(.hand(12)).foregroundStyle(CassettePalette.faded)
            } else {
                Text(calendar.access == .granted ? L("Hôm nay hết họp rồi ✌︎", "No more meetings today ✌︎")
                                                 : L("Soi lại trước khi lên hình", "Check yourself before the call"))
                    .font(.hand(14))
            }
        }
        .foregroundStyle(CassettePalette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(CassettePalette.note).shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 3))
        .rotationEffect(.degrees(-2))
    }

    private static func hm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }

    private static func untilText(_ item: CalendarStore.Item) -> String {
        let minutes = Int(item.start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return L("đang diễn ra", "happening now") }
        return L("sau \(minutes) phút", "in \(minutes) min")
    }
}

private struct ViewfinderCorners: Shape {
    func path(in r: CGRect) -> Path {
        let l: CGFloat = 18
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        return p
    }
}

/// Phím cơ có chữ (Lật / Đèn).
struct KeyButton: View {
    let title: String
    let pressed: Bool
    let lit: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hand(14))
                .foregroundStyle(CassettePalette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: pressed ? 31 : 35)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(lit ? Color(red: 1.0, green: 0.86, blue: 0.55) : (pressed ? CassettePalette.keyDown : CassettePalette.key))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.48, green: 0.42, blue: 0.32)))
                )
                .offset(y: pressed ? 2 : 0)
                .frame(height: 37, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Claude xin quyền → phiếu đánh máy + con dấu

struct CassettePermissionCard: View {
    let request: PermissionRequest
    let pending: Int
    let decide: (PermissionDecision) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinedPaper()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("PHIẾU XIN QUYỀN", "PERMISSION SLIP") + " · " + request.project)
                        .font(.typewriter(15, bold: true))
                        .lineLimit(1)
                    Spacer()
                    if pending > 1 { Text("+\(pending - 1)").font(.typewriter(12)) }
                }
                field(L("Người xin", "From"), "Claude Code")
                field(L("Công cụ", "Tool"), request.tool)
                field(L("Lệnh", "Command"), request.summary)
                if let detail = request.detail, !detail.isEmpty { field(L("Mục đích", "Purpose"), detail) }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    Spacer()
                    StampButton(text: L("BÁC", "DENY"), color: Color(red: 0.48, green: 0.48, blue: 0.48), tilt: -6) { decide(.deny) }
                    if request.canAlwaysAllow {
                        StampButton(text: L("LUÔN DUYỆT", "ALWAYS"), color: Color(red: 0.18, green: 0.44, blue: 0.82), tilt: 4) { decide(.allowAlways) }
                    }
                    StampButton(text: L("DUYỆT", "APPROVE"), color: CassettePalette.marker, tilt: -7) { decide(.allow) }
                }
            }
            .foregroundStyle(CassettePalette.ink)
            .padding(.leading, 42)
            .padding(.trailing, 18)
            .padding(.vertical, 12)
            Paperclip().stroke(Color(white: 0.6), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .frame(width: 16, height: 40)
                .offset(x: 16, y: -10)
        }
        .rotationEffect(.degrees(-0.8))
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":").font(.typewriter(12)).frame(width: 82, alignment: .leading)
            Text(value).font(.typewriter(13)).lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct LinedPaper: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.96, green: 0.93, blue: 0.84)))
            var y: CGFloat = 30
            while y < size.height {
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(Color(red: 0.61, green: 0.76, blue: 0.9).opacity(0.6)), lineWidth: 1)
                y += 20
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 32, y: 0)); $0.addLine(to: CGPoint(x: 32, y: size.height)) },
                       with: .color(CassettePalette.marker.opacity(0.7)), lineWidth: 1.4)
        }
        .shadow(color: .black.opacity(0.3), radius: 5, x: 3, y: 4)
    }
}

private struct Paperclip: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY + 8))
        p.addLine(to: CGPoint(x: r.minX + 2, y: r.maxY - 6))
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY - 6), radius: r.width / 2 - 2, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY + 5))
        p.addArc(center: CGPoint(x: r.midX + 1, y: r.minY + 5), radius: r.width / 2 - 3, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: r.minX + 5, y: r.maxY - 12))
        return p
    }
}

private struct StampButton: View {
    let text: String
    let color: Color
    let tilt: Double
    let action: () -> Void
    private var hover = State(initialValue: false)

    init(text: String, color: Color, tilt: Double, action: @escaping () -> Void) {
        self.text = text
        self.color = color
        self.tilt = tilt
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.typewriter(15, bold: true))
                .tracking(2)
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: 2.5))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).padding(4))
                .rotationEffect(.degrees(tilt))
                .scaleEffect(hover.wrappedValue ? 1.08 : 1)
                .opacity(hover.wrappedValue ? 1 : 0.85)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
    }
}

// MARK: - Claude hỏi → bảng ghim

struct Corkboard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(red: 0.72, green: 0.54, blue: 0.35))
            .overlay(
                Canvas { ctx, size in
                    var x: CGFloat = 6
                    while x < size.width {
                        var y: CGFloat = 6
                        while y < size.height {
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.4, height: 2.4)),
                                     with: .color(Color(red: 0.54, green: 0.39, blue: 0.25).opacity(0.7)))
                            y += 14
                        }
                        x += 16
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
