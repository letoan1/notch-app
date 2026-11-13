import SwiftUI

/// Màu kiểu app Calendar của macOS: hôm nay đỏ, chọn ngày khác thì vòng xám.
private let calendarRed = Color(red: 1.0, green: 0.27, blue: 0.23)

struct CalendarWidget: View {
    @ObservedObject var calendar: CalendarStore

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "vi_VN")
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(calendar.monthTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if calendar.weekOffset != 0 {
                    Button("Hôm nay") { calendar.resetToToday() }
                        .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1), text: .white.opacity(0.8)))
                        .controlSize(.mini)
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
                prompt("Cho phép đọc lịch", action: calendar.requestAccess)
            case .denied:
                prompt("Mở Cài đặt để cấp quyền lịch", action: calendar.openPrivacySettings)
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
            Text(calendar.isTodaySelected ? "Hôm nay không còn sự kiện" : "Không có sự kiện")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.prefix(2)) { item in
                    EventRow(item: item, isToday: calendar.isTodaySelected)
                }
                if items.count > 2 {
                    Text("+\(items.count - 2) sự kiện nữa")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { calendar.openCalendarApp() }
        }
    }

    private func prompt(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "calendar.badge.plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hover.wrappedValue ? 0.95 : 0.55))
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
                    isBusy: calendar.busyDays.contains(day)
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
    let select: () -> Void
    private var hover = State(initialValue: false)

    init(weekday: String, number: Int, isWeekend: Bool, isToday: Bool,
         isSelected: Bool, isBusy: Bool, select: @escaping () -> Void) {
        self.weekday = weekday
        self.number = number
        self.isWeekend = isWeekend
        self.isToday = isToday
        self.isSelected = isSelected
        self.isBusy = isBusy
        self.select = select
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Text(weekday)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(isWeekend ? 0.3 : 0.45))
                Text("\(number)")
                    .font(.system(size: 13, weight: isToday || isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(numberColor)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(circleFill))
                Circle()
                    .fill(.white.opacity(isBusy ? 0.55 : 0))
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover.wrappedValue && !isSelected ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return calendarRed }
        return .white.opacity(isWeekend ? 0.5 : 0.8)
    }

    private var circleFill: Color {
        guard isSelected else { return .clear }
        return isToday ? calendarRed : .white.opacity(0.22)
    }
}

private struct JoinButton: View {
    let meeting: CalendarStore.Meeting
    let prominent: Bool

    private let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        Button { NSWorkspace.shared.open(meeting.url) } label: {
            HStack(spacing: 3) {
                Image(systemName: "video.fill")
                Text(meeting.provider)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(prominent ? .white : blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(prominent ? blue : blue.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(meeting.url.absoluteString)
        .contextMenu {
            Button("Sao chép link") {
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
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
        if item.allDay { return "Cả ngày" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if isToday, item.start <= Date() { return "Đang diễn ra · đến \(f.string(from: item.end))" }
        return "\(f.string(from: item.start)) – \(f.string(from: item.end))"
    }
}
