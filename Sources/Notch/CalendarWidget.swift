import SwiftUI

/// Màu kiểu app Calendar của macOS: hôm nay đỏ, chọn ngày khác thì vòng xám.
private let calendarRed = Color(red: 1.0, green: 0.27, blue: 0.23)

/// Chữ trên nền tối: trắng (mặc định) hoặc kem (Van Gogh).
private func tone(_ opacity: Double) -> Color { Theme.isVanGogh ? VG.cream.opacity(min(1, opacity + 0.1)) : .white.opacity(opacity) }

struct CalendarWidget: View {
    @ObservedObject var calendar: CalendarStore

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Lang.locale
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(calendar.monthTitle)
                    .font(.ui(12, weight: .bold))
                    .foregroundStyle(tone(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if calendar.weekOffset != 0 {
                    Button { calendar.resetToToday() } label: {
                        Text(L("Hôm nay", "Today"))
                            .font(.ui(10.5, weight: .semibold))
                            .foregroundStyle(tone(0.85))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                NavButton(symbol: "chevron.left") { calendar.shiftWeek(-1) }
                NavButton(symbol: "chevron.right") { calendar.shiftWeek(1) }
            }
            .padding(.leading, 4)

            WeekStrip(calendar: calendar, cal: cal)
                .id(calendar.weekOffset)
                .transition(.opacity)
                // Kéo ngang dải ngày để chuyển tuần (minimumDistance để click ngày vẫn ăn).
                .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                    if value.translation.width < -30 { calendar.shiftWeek(1) }
                    if value.translation.width > 30 { calendar.shiftWeek(-1) }
                })

            switch calendar.access {
            case .granted:
                events
            case .notDetermined:
                prompt(L("Cho phép đọc lịch", "Allow calendar access"), action: calendar.requestAccess)
            case .denied:
                prompt(L("Mở Cài đặt để cấp quyền lịch", "Open Settings to allow calendar access"), action: calendar.openPrivacySettings)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: calendar.weekOffset)
    }

    @ViewBuilder
    private var events: some View {
        let items = calendar.selectedEvents
        if items.isEmpty {
            Text(calendar.isTodaySelected ? L("Hôm nay không còn sự kiện", "No more events today") : L("Không có sự kiện", "No events"))
                .font(.ui(11))
                .foregroundStyle(tone(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        } else {
            // Cuộn dọc trong phần còn lại: nhiều sự kiện không đẩy tiêu đề tháng ra ngoài.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        EventRow(item: item, isToday: calendar.isTodaySelected)
                    }
                }
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { calendar.openCalendarApp() }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func prompt(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "calendar.badge.plus")
                .font(.ui(11, weight: .semibold))
                .foregroundStyle(tone(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct NavButton: View {
    let symbol: String
    let action: () -> Void
    private var hover = State(initialValue: false)

    init(symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(10, weight: .semibold))
                .foregroundStyle(Theme.isVanGogh ? VG.cream.opacity(hover.wrappedValue ? 1 : 0.8) : .white.opacity(hover.wrappedValue ? 0.95 : 0.55))
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(hover.wrappedValue ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }
}

private struct WeekStrip: View {
    @ObservedObject var calendar: CalendarStore
    let cal: Calendar

    var body: some View {
        let today = cal.startOfDay(for: Date())
        HStack(spacing: 2) {
            ForEach(calendar.weekDays, id: \.self) { day in
                DayCell(
                    weekday: cal.veryShortWeekdaySymbols[cal.component(.weekday, from: day) - 1],
                    number: cal.component(.day, from: day),
                    isWeekend: cal.isDateInWeekend(day),
                    isToday: day == today,
                    isSelected: day == calendar.selectedDay,
                    isBusy: calendar.busyDays.contains(day),
                    load: calendar.dayLoad[day] ?? 0
                ) {
                    calendar.selectedDay = day
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: calendar.selectedDay)
    }
}

private struct DayCell: View {
    let weekday: String
    let number: Int
    let isWeekend: Bool
    let isToday: Bool
    let isSelected: Bool
    let isBusy: Bool
    var load = 0
    let select: () -> Void
    private var hover = State(initialValue: false)

    init(weekday: String, number: Int, isWeekend: Bool, isToday: Bool,
         isSelected: Bool, isBusy: Bool, load: Int = 0, select: @escaping () -> Void) {
        self.weekday = weekday
        self.number = number
        self.isWeekend = isWeekend
        self.isToday = isToday
        self.isSelected = isSelected
        self.isBusy = isBusy
        self.load = load
        self.select = select
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Text(weekday)
                    .font(.ui(9, weight: .medium))
                    .foregroundStyle(Theme.isVanGogh ? VG.muted.opacity(isWeekend ? 0.6 : 0.95) : .white.opacity(isWeekend ? 0.3 : 0.45))
                Text("\(number)")
                    .font(.ui(13, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(numberColor)
                    .frame(width: 22, height: 22)
                    .background(Theme.isPixel
                    ? AnyView(Rectangle().fill(isToday ? Color(red: 1, green: 0.3, blue: 0.3) : (isSelected ? PixelPalette.pink : Color(red: 0.1, green: 0.09, blue: 0.2)))
                        .overlay(Rectangle().strokeBorder(isToday || isSelected ? PixelPalette.border : PixelPalette.dim, lineWidth: 2)))
                    : Theme.isVanGogh ? AnyView(vgMark)
                    : AnyView(RoundedRectangle(cornerRadius: 11).fill(circleFill)))
                    // Pixel: các ô ngày nối bằng đường chấm như bản đồ chọn màn; hôm nay cắm cờ nhấp nháy.
                    .background { if Theme.isPixel { PixelMapPath().frame(width: 60) } }
                    .overlay(alignment: .topTrailing) { if Theme.isPixel && isToday { PixelTodayFlag().offset(x: 7, y: -8) } }
                if Theme.isPixel {
                    PixelMonsters(load: load)
                } else if Theme.isVanGogh {
                    // Ngày có sự kiện: hoa hướng dương, càng nhiều sự kiện hoa càng to.
                    let side = load == 0 ? 0 : load == 1 ? 11 : load == 2 ? 14 : 17
                    Group {
                        if side > 0 { Image(nsImage: VGArt.sunflower(side)) } else { Color.clear }
                    }
                    .frame(width: 17, height: 13)
                } else {
                Circle()
                    .fill(.white.opacity(isBusy ? 0.55 : 0))
                    .frame(width: 3, height: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover.wrappedValue && !isSelected ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }

    @ViewBuilder private var vgMark: some View {
        if isToday {
            VGSwirlHalo().frame(width: 28, height: 28)
        } else if isSelected {
            Circle().stroke(VG.yellow, lineWidth: 1.6)
        }
    }

    private var numberColor: Color {
        if Theme.isPixel { return isToday || isSelected ? .white : .white.opacity(0.85) }
        if Theme.isVanGogh { return isToday ? VG.ink : VG.cream.opacity(isWeekend && !isSelected ? 0.65 : 1) }
        if isSelected { return .white }
        if isToday { return calendarRed }
        return .white.opacity(isWeekend ? 0.5 : 0.8)
    }

    private var circleFill: Color {
        guard isSelected else { return .clear }
        return isToday ? calendarRed : .white.opacity(0.22)
    }
}

struct JoinButton: View {
    let meeting: CalendarStore.Meeting
    let prominent: Bool

    private let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        Button { NSWorkspace.shared.open(meeting.url) } label: {
            HStack(spacing: 3) {
                Image(systemName: "video.fill")
                Text(meeting.provider)
            }
            .font(.ui(10, weight: .semibold))
            .foregroundStyle(Theme.isVanGogh ? VG.ink : prominent ? .white : blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.isVanGogh
                        ? AnyView(Capsule().fill(VG.yellow).overlay(Capsule().stroke(VG.ink, lineWidth: 1.2)))
                        : AnyView(ThemedBackground(fill: prominent ? blue : blue.opacity(0.18))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(meeting.url.absoluteString)
        .contextMenu {
            Button(L("Sao chép link", "Copy link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meeting.url.absoluteString, forType: .string)
            }
        }
    }
}

private struct EventRow: View {
    let item: CalendarStore.Item
    let isToday: Bool

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(item.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.ui(12, weight: .bold))
                    .foregroundStyle(tone(0.9))
                    .lineLimit(1)
                Text(timeText)
                    .font(.ui(11).monospacedDigit())
                    .foregroundStyle(tone(0.5))
            }
            Spacer(minLength: 4)
            if let meeting = item.meeting {
                JoinButton(meeting: meeting, prominent: true)
            }
        }
        .padding(.leading, 4)
    }

    /// Sắp bắt đầu trong 10 phút hoặc đang diễn ra.
    private var isSoon: Bool {
        let now = Date()
        return !item.allDay && item.start.addingTimeInterval(-600) <= now && item.end > now
    }

    private var timeText: String {
        if item.allDay { return L("Cả ngày", "All day") }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if isToday, item.start <= Date() { return L("Đang diễn ra · đến \(f.string(from: item.end))", "Now · until \(f.string(from: item.end))") }
        return "\(f.string(from: item.start)) – \(f.string(from: item.end))"
    }
}
