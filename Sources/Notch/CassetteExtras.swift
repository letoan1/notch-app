import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Góc analog thập niên 80 (giao diện Cassette): nhiễu băng khi tua, lịch bloc xé, đĩa mềm + băng trượt vào khe,
/// máy ảnh lấy liền, phiếu telex in từng dòng + đóng dấu.

// MARK: - Nhạc: nhiễu băng khi tua

/// Vạch quét ngang + đốm nhiễu, chỉ hiện (và chỉ vẽ lại) trong lúc đang tua.
struct TapeNoise: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            Canvas { g, size in
                var rng = SeededRNG(UInt64(ctx.date.timeIntervalSinceReferenceDate * 20) & 0xffff)
                var y: CGFloat = 0
                while y < size.height {
                    g.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.22)))
                    y += 3
                }
                for _ in 0..<5 {
                    let yy = CGFloat(rng.range(0, Double(size.height)))
                    g.fill(Path(CGRect(x: 0, y: yy, width: size.width, height: CGFloat(rng.range(1, 3)))),
                           with: .color(.white.opacity(rng.range(0.15, 0.45))))
                }
                for _ in 0..<60 {
                    let x = CGFloat(rng.range(0, Double(size.width))), yy = CGFloat(rng.range(0, Double(size.height)))
                    g.fill(Path(CGRect(x: x, y: yy, width: 1.5, height: 1.5)), with: .color(.white.opacity(rng.range(0.2, 0.6))))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Lịch bloc xé

struct TearOffCalendar: View {
    @ObservedObject var calendar: CalendarStore
    /// Tờ cũ đang bị xé bay đi (ngày + sự kiện lúc đó).
    private var tearing = State<(day: Date, items: [CalendarStore.Item])?>(initialValue: nil)
    private var tear = State(initialValue: CGFloat(0))
    private var shown = State(initialValue: [CalendarStore.Item]())

    init(calendar: CalendarStore) {
        self.calendar = calendar
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Lang.locale
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            binder
            weekRow
            ZStack(alignment: .top) {
                // Mép các tờ bên dưới.
                ForEach(0..<3, id: \.self) { i in
                    Rectangle().fill(Color(red: 0.93 - Double(i) * 0.04, green: 0.9 - Double(i) * 0.04, blue: 0.82 - Double(i) * 0.04))
                        .offset(y: CGFloat(3 - i) * 2)
                }
                page(calendar.selectedDay, items: calendar.access == .granted ? calendar.selectedEvents : [])
                if let old = tearing.wrappedValue {
                    page(old.day, items: old.items)
                        .modifier(PageTear(progress: tear.wrappedValue))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: Self.pageHeight)
        }
        .frame(width: 226, height: 18 + 22 + Self.pageHeight, alignment: .top)
        .shadow(color: .black.opacity(0.35), radius: 6, x: 3, y: 4)
        .rotationEffect(.degrees(-1.5))
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { shown.wrappedValue = calendar.selectedEvents }
        .onChange(of: calendar.selectedDay) { old, _ in
            tearing.wrappedValue = (old, shown.wrappedValue)
            shown.wrappedValue = calendar.selectedEvents
            tear.wrappedValue = 0
            withAnimation(.easeIn(duration: 0.55)) { tear.wrappedValue = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if tear.wrappedValue >= 1 { tearing.wrappedValue = nil }
            }
        }
        .onChange(of: calendar.selectedEvents.map(\.id)) { _, _ in shown.wrappedValue = calendar.selectedEvents }
    }

    /// Gáy lịch đỏ với hai khoen.
    private var binder: some View {
        ZStack {
            Rectangle().fill(Color(red: 0.62, green: 0.16, blue: 0.14))
            HStack(spacing: 120) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule().fill(Color(white: 0.75)).frame(width: 7, height: 16)
                        .overlay(Capsule().stroke(Color(white: 0.45), lineWidth: 1))
                        .offset(y: -5)
                }
            }
            Text(calendar.monthTitle).font(.hand(11)).foregroundStyle(CassettePalette.label).lineLimit(1)
        }
        .frame(height: 18)
    }

    private var weekRow: some View {
        HStack(spacing: 0) {
            Button { calendar.shiftWeek(-1) } label: { Image(systemName: "chevron.left").frame(width: 16, height: 20) }
                .buttonStyle(.plain)
            ForEach(calendar.weekDays, id: \.self) { day in
                let selected = day == calendar.selectedDay
                Button { calendar.selectedDay = day } label: {
                    Text("\(cal.component(.day, from: day))")
                        .font(.hand(12))
                        .foregroundStyle(cal.isDateInWeekend(day) ? CassettePalette.weekend : CassettePalette.ink)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background { if selected { Rectangle().fill(CassettePalette.note) } }
                        .overlay(alignment: .bottom) {
                            if calendar.busyDays.contains(day) { Circle().fill(CassettePalette.marker).frame(width: 3, height: 3) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { calendar.shiftWeek(1) } label: { Image(systemName: "chevron.right").frame(width: 16, height: 20) }
                .buttonStyle(.plain)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(CassettePalette.ink.opacity(0.7))
        .padding(.horizontal, 2)
        .frame(height: 22)
        .background(Color(red: 0.84, green: 0.79, blue: 0.68))
    }

    /// Cao vừa khung mở chung với các giao diện khác (gáy 18 + hàng tuần 22 + tờ lịch).
    static let pageHeight: CGFloat = 90
    /// Số dòng việc thấy được trên tờ; nhiều hơn thì cuộn + nhãn "+n".
    private static let visibleRows = 3

    private func page(_ day: Date, items: [CalendarStore.Item]) -> some View {
        let weekend = cal.isDateInWeekend(day)
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = "EEEE"
        let now = Date()
        let nextJoin = items.first { $0.meeting != nil && $0.end > now }?.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(cal.component(.day, from: day))")
                    .font(.hand(25))
                    .foregroundStyle(weekend ? CassettePalette.marker : CassettePalette.ink)
                Text(f.string(from: day).capitalized(with: Lang.locale)).font(.hand(14)).foregroundStyle(CassettePalette.ink)
                if cal.isDateInToday(day) {
                    Text(L("hôm nay", "today")).font(.hand(11)).foregroundStyle(CassettePalette.marker)
                }
                Spacer(minLength: 0)
            }
            if calendar.access == .granted {
                if items.isEmpty {
                    Text(L("Trống trơn ✌︎", "Nothing planned ✌︎")).font(.hand(13)).foregroundStyle(CassettePalette.ink.opacity(0.6))
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(items) { item in
                                HStack(spacing: 5) {
                                    Text(Self.time(item)).font(.hand(12)).foregroundStyle(CassettePalette.marker)
                                        .frame(width: 34, alignment: .leading)
                                    Text(item.title).font(.hand(12.5)).foregroundStyle(CassettePalette.ink).lineLimit(1)
                                    Spacer(minLength: 2)
                                    if let meeting = item.meeting, item.id == nextJoin {
                                        JoinButton(meeting: meeting, prominent: true)
                                    } else if item.meeting != nil {
                                        Image(systemName: "video").font(.system(size: 9)).foregroundStyle(CassettePalette.faded)
                                    }
                                }
                                .frame(height: 17)
                                .opacity(item.end < now && !item.allDay ? 0.5 : 1)
                            }
                        }
                    }
                    .frame(maxHeight: CGFloat(Self.visibleRows) * 18)
                    .overlay(alignment: .bottomTrailing) {
                        if items.count > Self.visibleRows {
                            Text(L("+\(items.count - Self.visibleRows) việc, cuộn xuống", "+\(items.count - Self.visibleRows) more, scroll"))
                                .font(.hand(10))
                                .foregroundStyle(CassettePalette.faded)
                                .padding(.horizontal, 4)
                                .background(Color(red: 0.97, green: 0.95, blue: 0.88))
                                .allowsHitTesting(false)
                        }
                    }
                }
            } else {
                Button(L("Bấm để cho phép đọc lịch", "Click to allow calendar access")) {
                    if calendar.access == .notDetermined { calendar.requestAccess() } else { calendar.openPrivacySettings() }
                }
                .font(.hand(13))
                .foregroundStyle(CassettePalette.ink)
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .frame(width: 226, height: Self.pageHeight, alignment: .topLeading)
        .background(Color(red: 0.97, green: 0.95, blue: 0.88))
        .overlay(alignment: .top) {
            // Hàng lỗ xé ở mép trên.
            HStack(spacing: 5) {
                ForEach(0..<30, id: \.self) { _ in Circle().fill(Color(red: 0.84, green: 0.79, blue: 0.68)).frame(width: 2.5, height: 2.5) }
            }
            .padding(.top, 2)
        }
        .clipped()
    }

    private static func time(_ item: CalendarStore.Item) -> String {
        if item.allDay { return L("cả ngày", "all day") }
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: item.start)
    }
}

/// Tờ lịch bị xé: mép trên rách răng cưa, lật lên và bay sang phải.
private struct PageTear: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask(TornTop(depth: 5 * min(1, progress * 6)))
            .rotationEffect(.degrees(Double(16 * progress)), anchor: .topLeading)
            .offset(x: 130 * progress, y: -46 * progress + 60 * progress * progress)
            .opacity(Double(1 - progress * progress))
    }
}

private struct TornTop: Shape {
    var depth: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + depth))
        var x = r.minX
        var up = true
        while x < r.maxX {
            x = min(x + 5, r.maxX)
            p.addLine(to: CGPoint(x: x, y: r.minY + (up ? 0 : depth)))
            up.toggle()
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Khay: đĩa mềm, băng trượt vào khe / bật ra

/// Đĩa mềm 3,5": thân màu theo loại file, nắp trượt kim loại, nhãn viết tay.
struct FloppyDisk: View {
    let url: URL

    var body: some View {
        let tint = fileTint(url)
        ZStack(alignment: .top) {
            FloppyShape().fill(tint.opacity(0.85))
            FloppyShape().fill(LinearGradient(colors: [.black.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom))
            FloppyShape().stroke(Color.black.opacity(0.45), lineWidth: 1.2)
            // Nắp kim loại + khe
            ZStack {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.78))
                RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.32)).frame(width: 7, height: 15).offset(x: 6)
            }
            .frame(width: 36, height: 21)
            .offset(x: 2)
            // Nhãn
            VStack(spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping)
                    .font(.custom("Bradley Hand", size: 10).weight(.bold))
                    .foregroundStyle(CassettePalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(url.pathExtension.uppercased())
                    .font(.hand(9))
                    .foregroundStyle(CassettePalette.marker)
            }
            .padding(3)
            .frame(width: 50, height: 34)
            .background(CassettePalette.label)
            .overlay(alignment: .top) { Rectangle().fill(CassettePalette.band).frame(height: 3) }
            .offset(y: 28)
            // Lỗ chống ghi
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: 5, height: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(4)
        }
        .frame(width: 66, height: 68)
    }
}

private struct FloppyShape: Shape {
    func path(in r: CGRect) -> Path {
        let c: CGFloat = 7
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 3, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 3))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 3, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 3, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 3), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 3))
        p.addQuadCurve(to: CGPoint(x: r.minX + 3, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Băng / đĩa mới: trượt từ trên xuống vào khe, nảy nhẹ (lần đầu tile hiện ra).
struct CassetteSlideIn: ViewModifier {
    private var progress: State<CGFloat>
    private let url: URL
    private let tray: TrayStore

    init(url: URL, tray: TrayStore) {
        self.url = url
        self.tray = tray
        progress = State(initialValue: tray.fresh.contains(url) ? 0 : 1)
    }

    func body(content: Content) -> some View {
        let k = 1 - progress.wrappedValue
        content
            .offset(y: -58 * k)
            .rotationEffect(.degrees(Double(-6 * k)))
            .opacity(Double(min(1, progress.wrappedValue * 2.5)))
            .onAppear {
                guard tray.takeFresh(url) else { return }
                progress.wrappedValue = 0
                withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { progress.wrappedValue = 1 }
            }
    }
}

/// Gỡ: bật ra khỏi khe (vọt lên, nghiêng, mờ dần).
struct TapeEject: ViewModifier, Animatable {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(y: -70 * amount)
            .rotationEffect(.degrees(Double(-10 * amount)))
            .opacity(Double(1 - amount))
    }
}

/// Khay trống: hộp đựng băng rỗng đang mở nắp; kéo file tới thì nắp mở rộng thêm.
struct EmptyCaseZone: View {
    let targeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(red: 0.14, green: 0.12, blue: 0.11))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(targeted ? CassettePalette.band : CassettePalette.shellEdge, lineWidth: 2))
            .overlay {
                HStack(spacing: 22) {
                    caseArt.frame(width: 110, height: 86)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(targeted ? L("Thả vào hộp đi!", "Drop it in the case!")
                                      : L("Nhét băng vào đây · kéo file lên notch", "Slot a tape in · drag files onto the notch"))
                            .font(.hand(17))
                            .foregroundStyle(CassettePalette.key)
                        Text(L("Kéo ra để thả vào bất cứ đâu. Chuột phải để AirDrop hoặc chia sẻ.",
                               "Drag out to drop anywhere. Right-click to AirDrop or share."))
                            .font(.hand(12))
                            .foregroundStyle(CassettePalette.key.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .padding(.horizontal, 24)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: targeted)
    }

    private var caseArt: some View {
        ZStack(alignment: .bottom) {
            // Đáy hộp: khay nhựa trong + bìa giấy
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                VStack(spacing: 3) {
                    Rectangle().fill(CassettePalette.band).frame(height: 6)
                    ForEach(0..<3, id: \.self) { _ in Rectangle().fill(CassettePalette.line).frame(height: 1) }
                }
                .padding(.horizontal, 10)
                .offset(y: -4)
                HStack(spacing: 26) {
                    Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5).frame(width: 12, height: 12)
                    Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5).frame(width: 12, height: 12)
                }
                .offset(y: 12)
            }
            .frame(width: 104, height: 48)
            // Nắp mở quanh bản lề dưới
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.55), lineWidth: 1.5))
                .overlay(Rectangle().fill(Color.white.opacity(0.18)).frame(width: 30, height: 2).rotationEffect(.degrees(-30)).offset(x: 20, y: -10))
                .frame(width: 104, height: 48)
                .rotation3DEffect(.degrees(targeted ? 72 : 42), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
                .offset(y: -48)
        }
    }
}

// MARK: - Gương: máy ảnh lấy liền

struct InstantCameraMirror: View {
    @ObservedObject var camera: CameraMirror
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var tray: TrayStore
    @ObservedObject var edge = EdgeLight.shared
    /// Tấm ảnh đang trồi ra và hiện dần.
    private var print = State<NSImage?>(initialValue: nil)
    private var out = State(initialValue: CGFloat(0))
    private var develop = State(initialValue: CGFloat(0))
    private var busy = State(initialValue: false)

    init(camera: CameraMirror, calendar: CalendarStore, tray: TrayStore) {
        self.camera = camera
        self.calendar = calendar
        self.tray = tray
    }

    var body: some View {
        HStack(spacing: 16) {
            cameraBody.frame(width: 300)
                .overlay(alignment: .trailing) { printView }
                .zIndex(1)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Sẵn sàng họp?", "Ready for the call?")).font(.hand(20)).foregroundStyle(CassettePalette.key)
                meetingNote
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    KeyButton(title: busy.wrappedValue ? L("Đang in…", "Printing…") : L("● Chụp", "● Snap"),
                              pressed: busy.wrappedValue, lit: !busy.wrappedValue) { snap() }
                        .help(L("Chụp ảnh lấy liền, lưu vào khay và thư mục Ảnh › Roost", "Take an instant photo, saved to the tray and Pictures › Roost"))
                    KeyButton(title: camera.mirrored ? L("⇄ Gương", "⇄ Mirror") : L("⇄ Thật", "⇄ True"),
                              pressed: false, lit: false) { camera.mirrored.toggle() }
                    KeyButton(title: edge.level.title, pressed: edge.isOn, lit: edge.isOn) { edge.cycle() }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    /// Thân máy ảnh: nửa trên kem, nửa dưới nâu, sọc cam, ống kính tròn ở góc, khung ngắm là camera thật.
    private var cameraBody: some View {
        ZStack {
            VStack(spacing: 0) {
                Color(red: 0.93, green: 0.9, blue: 0.83)
                Color(red: 0.36, green: 0.25, blue: 0.18).frame(height: 26)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.48, green: 0.42, blue: 0.32), lineWidth: 1.5))
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    CassettePalette.band.frame(width: 60, height: 4)
                    Color(red: 1, green: 0.78, blue: 0.3).frame(width: 60, height: 4)
                }
                .padding(.bottom, 26)
            }
            Group {
                switch camera.access {
                case .granted:
                    CameraPreview(session: camera.session, cornerRadius: 6, mirrored: camera.mirrored)
                        .overlay { if camera.frameState == .live { MirrorGuideOverlay(hint: camera.guide) } }
                        .overlay { if camera.frameState != .live { noFrames } }
                case .notDetermined:
                    placeholder(L("Bấm để bật máy ảnh", "Click to turn on the camera"), action: camera.requestAccess)
                case .denied:
                    placeholder(L("Mở Cài đặt để cấp quyền camera", "Open Settings to allow camera access"), action: camera.openPrivacySettings)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 36)
            // Ống kính + đèn flash ở đáy nâu
            HStack {
                Circle().fill(Color(white: 0.12)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color(white: 0.6), lineWidth: 2))
                    .overlay(Circle().fill(Color(red: 0.3, green: 0.4, blue: 0.6).opacity(0.7)).frame(width: 6, height: 6).offset(x: -2, y: -2))
                Spacer()
                Text(L("ẢNH LẤY LIỀN", "INSTANT")).font(.typewriter(9, bold: true)).foregroundStyle(CassettePalette.label.opacity(0.8))
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.85)).frame(width: 22, height: 10)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 4)
        }
    }

    /// Tấm ảnh trồi ra bên phải thân máy, hiện dần từ tối sang có hình trong ~2 s.
    @ViewBuilder private var printView: some View {
        if let image = print.wrappedValue {
            VStack(spacing: 0) {
                ZStack {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 72).clipped()
                        .saturation(Double(0.2 + 0.8 * develop.wrappedValue))
                    Color(red: 0.12, green: 0.1, blue: 0.14).opacity(Double(1 - develop.wrappedValue))
                }
                .frame(width: 96, height: 72)
                Text(Self.caption).font(.hand(11)).foregroundStyle(CassettePalette.ink).frame(height: 22)
            }
            .padding(.horizontal, 6).padding(.top, 6)
            .background(Color(red: 0.98, green: 0.97, blue: 0.93))
            .shadow(color: .black.opacity(0.45), radius: 4, x: 2, y: 3)
            .rotationEffect(.degrees(Double(4 * out.wrappedValue)))
            .offset(x: 100 * out.wrappedValue, y: 6)
            .opacity(Double(min(1, out.wrappedValue * 4)))
            .allowsHitTesting(false)
        }
    }

    private static var caption: String {
        let f = DateFormatter()
        f.dateFormat = "d/M/yy"
        return f.string(from: Date())
    }

    private var noFrames: some View {
        RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.23, green: 0.2, blue: 0.17))
            .overlay(VStack(spacing: 5) {
                Text(camera.frameState == .starting ? L("Đang bật máy ảnh…", "Starting the camera…") : L("Máy ảnh chưa có hình", "No picture from the camera"))
                    .font(.hand(15))
                if camera.frameState == .none {
                    Text(L("Mở nắp máy, hoặc tắt app khác đang dùng camera", "Open the lid, or quit other apps using the camera"))
                        .font(.hand(12)).opacity(0.75).multilineTextAlignment(.center).padding(.horizontal, 14)
                }
            }
            .foregroundStyle(CassettePalette.key))
            .allowsHitTesting(false)
    }

    private func placeholder(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.23, green: 0.2, blue: 0.17))
                .overlay(Text(text).font(.hand(14)).foregroundStyle(CassettePalette.key).multilineTextAlignment(.center))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var meetingNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let next = calendar.nextEvent {
                HStack(spacing: 6) {
                    Text("• \(next.title)").font(.hand(14)).lineLimit(1)
                    Spacer(minLength: 2)
                    if let meeting = next.meeting { JoinButton(meeting: meeting, prominent: true) }
                }
                let minutes = Int(next.start.timeIntervalSinceNow / 60)
                Text(minutes <= 0 ? L("đang diễn ra", "happening now") : L("sau \(minutes) phút", "in \(minutes) min"))
                    .font(.hand(12)).foregroundStyle(CassettePalette.faded)
            } else {
                Text(calendar.access == .granted ? L("Hôm nay hết họp rồi ✌︎", "No more meetings today ✌︎")
                                                 : L("Soi lại trước khi lên hình", "Check yourself before the call"))
                    .font(.hand(14))
            }
        }
        .foregroundStyle(CassettePalette.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(CassettePalette.note).shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 3))
        .rotationEffect(.degrees(-2))
    }

    private func snap() {
        guard !busy.wrappedValue, camera.access == .granted else { return }
        busy.wrappedValue = true
        Haptics.tap(.levelChange)
        let mirrored = camera.mirrored
        // Ảnh gốc từ bộ chụp ảnh; camera chưa sẵn sàng thì lấy khung hình như cũ.
        let handle: (CGImage?) -> Void = { cg in
            guard let cg else { busy.wrappedValue = false; return }
            var photo = CIImage(cgImage: cg)
            if mirrored {
                photo = photo.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -photo.extent.width, y: 0))
            }
            if let rendered = OilPaint.context.createCGImage(photo, from: photo.extent) {
                print.wrappedValue = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            }
            out.wrappedValue = 0
            develop.wrappedValue = 0
            withAnimation(.easeOut(duration: 0.7)) { out.wrappedValue = 1 }
            withAnimation(.easeInOut(duration: 2).delay(0.5)) { develop.wrappedValue = 1 }
            Painterly.save(photo, name: L("Ảnh lấy liền", "Instant photo")) { url in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    if let url { tray.add(url) }
                    withAnimation(.easeIn(duration: 0.35)) { print.wrappedValue = nil }
                    busy.wrappedValue = false
                }
            }
        }
        camera.capturePhoto { cg in
            if let cg { handle(cg) } else { camera.snapshot(handle) }
        }
    }
}

// MARK: - Claude: phiếu telex

/// Giấy in liên tục: lỗ kéo giấy hai bên, dải xanh nhạt xen kẽ.
struct TelexPaper: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.97, green: 0.96, blue: 0.9)))
            var y: CGFloat = 0
            var band = false
            while y < size.height {
                if band {
                    ctx.fill(Path(CGRect(x: 22, y: y, width: size.width - 44, height: 18)),
                             with: .color(Color(red: 0.8, green: 0.9, blue: 0.8).opacity(0.45)))
                }
                band.toggle()
                y += 18
            }
            for side in [CGFloat(11), size.width - 11] {
                var hy: CGFloat = 8
                while hy < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: side - 3.5, y: hy - 3.5, width: 7, height: 7)),
                             with: .color(Color(red: 0.14, green: 0.12, blue: 0.11)))
                    hy += 16
                }
                ctx.stroke(Path { $0.move(to: CGPoint(x: side == 11 ? 22 : size.width - 22, y: 0))
                                  $0.addLine(to: CGPoint(x: side == 11 ? 22 : size.width - 22, y: size.height)) },
                           with: .color(Color(white: 0.6)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 5, x: 2, y: 4)
    }
}

/// Dấu cao su đóng lên phiếu ngay khi bấm (trước khi gửi quyết định).
struct RubberStamp: View {
    let text: String
    let color: Color
    private var landed = State(initialValue: false)

    init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.typewriter(26, bold: true))
            .tracking(3)
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 3.5))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])).padding(5))
            .rotationEffect(.degrees(-10))
            .opacity(landed.wrappedValue ? 0.88 : 0)
            .scaleEffect(landed.wrappedValue ? 1 : 1.8)
            .onAppear { withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) { landed.wrappedValue = true } }
            .allowsHitTesting(false)
    }
}
