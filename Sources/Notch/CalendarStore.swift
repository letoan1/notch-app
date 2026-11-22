import AppKit
import EventKit
import SwiftUI

@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: Color
        let meeting: Meeting?
    }

    struct Meeting: Equatable {
        let url: URL
        let provider: String
    }

    private static let meetingPattern =
        #"https://(meet\.google\.com/[a-z0-9-]+|[a-z0-9.-]*zoom\.us/(j|my|w)/[^\s<>"']+|teams\.(microsoft\.com|live\.com)/(l/meetup-join|meet)/[^\s<>"']+|[a-z0-9.-]+\.webex\.com/(meet|join|[a-z0-9.-]+/j\.php)[^\s<>"']*)"#

    /// Tìm link họp trong url / location / notes của sự kiện (Google Calendar hay để ở notes).
    private static func meeting(in event: EKEvent) -> Meeting? {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in fields {
            guard let range = text.range(of: meetingPattern, options: [.regularExpression, .caseInsensitive]),
                  let url = URL(string: String(text[range]))
            else { continue }
            let host = url.host ?? ""
            let provider = host.contains("zoom") ? "Zoom" : host.contains("teams") ? "Teams"
                : host.contains("webex") ? "Webex" : "Meet"
            return Meeting(url: url, provider: provider)
        }
        return nil
    }

    @Published private(set) var access: Access
    /// Mọi sự kiện trong dải 7 ngày.
    @Published private(set) var windowEvents: [Item] = []
    /// Các ngày (startOfDay) trong dải 7 ngày có ít nhất 1 sự kiện.
    @Published private(set) var busyDays: Set<Date> = []
    /// Số sự kiện mỗi ngày trong dải (giao diện Van Gogh: hoa hướng dương to dần).
    @Published private(set) var dayLoad: [Date: Int] = [:]
    /// Ngày đang xem (startOfDay), mặc định hôm nay.
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Lệch bao nhiêu tuần so với tuần chứa hôm nay.
    @Published private(set) var weekOffset = 0
    /// Chiều chuyển tuần gần nhất (+1 sau, -1 trước): tuần mới trượt vào từ phía tương ứng.
    @Published private(set) var lastShift = 1

    func shiftWeek(_ delta: Int) {
        lastShift = delta > 0 ? 1 : -1
        weekOffset += delta
        // Dải 7 ngày mới không giao dải cũ → chọn hôm nay nếu quay về, không thì ngày giữa dải.
        selectedDay = weekOffset == 0 ? Calendar.current.startOfDay(for: Date()) : weekDays[3]
        reload()
    }

    /// "Tháng 11, 2026" theo ngày đang chọn.
    var monthTitle: String {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = Lang.isVietnamese ? "'Tháng' M, yyyy" : "MMMM yyyy"
        return f.string(from: selectedDay)
    }

    var isTodaySelected: Bool { selectedDay == Calendar.current.startOfDay(for: Date()) }

    /// Sự kiện của ngày đang chọn; với hôm nay thì bỏ các sự kiện đã kết thúc.
    var selectedEvents: [Item] {
        let cal = Calendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: selectedDay)!
        let lowerBound = isTodaySelected ? Date() : selectedDay
        return windowEvents.filter { $0.start < dayEnd && $0.end > lowerBound }
    }

    /// Sự kiện có giờ sắp tới (hoặc đang diễn ra) trong hôm nay, cho tab gương.
    var nextEvent: Item? {
        let now = Date()
        let cal = Calendar.current
        return windowEvents.first {
            !$0.allDay && $0.end > now && cal.isDateInToday($0.start)
        }
    }

    func resetToToday() {
        if weekOffset != 0 {
            shiftWeek(-weekOffset)
        } else {
            selectedDay = Calendar.current.startOfDay(for: Date())
        }
    }

    private let store = EKEventStore()
    /// Hẹn một lần tới mốc kế tiếp (sự kiện sắp tới / bắt đầu / kết thúc, nửa đêm), không chạy đều mỗi phút.
    private var boundaryTimer: Timer?

    init() {
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Sang ngày mới, đổi múi giờ, máy thức dậy: giờ "bây giờ" đã nhảy, vẽ lại và đọc lại.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundaryReached() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundaryReached() }
        }
        reload()
    }

    /// Tới một mốc thời gian: dữ liệu có thể không đổi nhưng giao diện tính theo "bây giờ" (cánh họp, "sắp họp",
    /// bỏ sự kiện đã qua) phải vẽ lại.
    private func boundaryReached() {
        objectWillChange.send()
        reload()
    }

    private func scheduleBoundary() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        let now = Date()
        let cal = Calendar.current
        var marks: [Date] = [cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!]
        for e in windowEvents where !e.allDay {
            marks += [e.start.addingTimeInterval(-WingLayout.meetingWindow), e.start.addingTimeInterval(-600), e.start, e.end]
        }
        guard let next = marks.filter({ $0 > now.addingTimeInterval(0.5) }).min() else { return }
        let t = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundaryReached() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        boundaryTimer = t
    }

    /// Dải 7 ngày quanh tâm (hôm nay + weekOffset tuần): 3 ngày trước, tâm, 3 ngày sau.
    var weekDays: [Date] { days(week: weekOffset) }

    func days(week: Int) -> [Date] {
        let cal = Calendar.current
        let center = cal.date(byAdding: .day, value: 7 * week, to: cal.startOfDay(for: Date()))!
        return (-3...3).compactMap { cal.date(byAdding: .day, value: $0, to: center) }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.access = granted ? .granted : .denied
                    self?.reload()
                }
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    func reload() {
        access = Self.currentAccess()
        let days = weekDays
        // Sang ngày mới mà ngày đang chọn đã trôi khỏi dải → chọn ngày giữa dải.
        if !days.contains(selectedDay) { selectedDay = days[3] }
        guard access == .granted, let first = days.first, let last = days.last else {
            if !windowEvents.isEmpty { windowEvents = [] }
            if !busyDays.isEmpty { busyDays = [] }
            if !dayLoad.isEmpty { dayLoad = [:] }
            scheduleBoundary()
            return
        }
        let windowEnd = Calendar.current.date(byAdding: .day, value: 1, to: last)!
        // EventKit đọc trên luồng nền (đổi tuần không làm khựng hiệu ứng); vuốt nhiều tuần liền thì chỉ áp kết quả mới nhất.
        reloadGen += 1
        let gen = reloadGen, store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            nonisolated(unsafe) let raw = store.events(matching: store.predicateForEvents(withStart: first, end: windowEnd, calendars: nil))
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, gen == self.reloadGen else { return }
                    self.apply(Self.dropDuplicateHolidays(raw), days: days)
                }
            }
        }
    }

    private var reloadGen = 0

    private func apply(_ events: [EKEvent], days: [Date]) {
        let cal = Calendar.current
        // Sự kiện nhiều ngày đánh dấu mọi ngày nó phủ.
        var load: [Date: Int] = [:]
        for day in days {
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            let n = events.filter { $0.startDate < end && $0.endDate > day }.count
            if n > 0 { load[day] = n }
        }
        // Chỉ gán khi khác: mỗi lần gán là cả notch vẽ lại.
        if load != dayLoad { dayLoad = load }
        if Set(load.keys) != busyDays { busyDays = Set(load.keys) }

        let items = events
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map {
                // Các lần lặp của một sự kiện lặp lại dùng chung eventIdentifier: thêm giờ bắt đầu cho id riêng, ổn định.
                Item(id: "\($0.eventIdentifier ?? $0.title ?? "")|\($0.startDate.timeIntervalSince1970)",
                     title: $0.title ?? L("(Không tiêu đề)", "(No title)"),
                     start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                     color: Color(nsColor: $0.calendar?.color ?? .systemBlue),
                     meeting: Self.meeting(in: $0))
            }
        if items != windowEvents { windowEvents = items }
        scheduleBoundary()
    }

    /// Có cả lịch ngày lễ tiếng Anh lẫn tiếng Việt ("Holidays in Vietnam" + "Ngày lễ ở Việt Nam") thì mỗi ngày lễ
    /// hiện hai lần: chỉ giữ lịch ngày lễ đúng ngôn ngữ của Roost.
    static func dropDuplicateHolidays(_ events: [EKEvent]) -> [EKEvent] {
        func isHoliday(_ c: EKCalendar) -> Bool {
            let t = c.title.lowercased()
            return t.contains("holiday") || t.contains("ngày lễ") || t.contains("ngày nghỉ")
        }
        let holidays = Dictionary(grouping: events.compactMap(\.calendar).filter(isHoliday), by: \.calendarIdentifier)
            .compactMap(\.value.first)
        guard holidays.count > 1 else { return events }
        // Tên lịch có dấu tiếng Việt = lịch tiếng Việt.
        func vietnamese(_ c: EKCalendar) -> Bool { c.title.folding(options: .diacriticInsensitive, locale: nil) != c.title }
        guard let keep = holidays.first(where: { vietnamese($0) == Lang.isVietnamese }) else { return events }
        return events.filter { e in
            guard let c = e.calendar, isHoliday(c) else { return true }
            return c.calendarIdentifier == keep.calendarIdentifier
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

/// Dải ngày bám theo ngón tay khi vuốt ngang (pt). Tách khỏi CalendarStore: chỉ dải ngày theo dõi giá trị này,
/// nên mỗi sự kiện cuộn không làm cả notch vẽ lại.
@MainActor
final class WeekDrag: ObservableObject {
    static let shared = WeekDrag()
    @Published var offset: CGFloat = 0
    /// Chiều rộng một tuần trên màn hình (đo từ dải ngày).
    var width: CGFloat = 300
    private var paging = false

    /// Lật sang tuần sau (+1) / trước (-1): trượt hết một trang rồi mới đổi tuần, không có cú nhảy.
    func page(_ dir: Int, commit: @escaping @MainActor () -> Void) {
        guard !paging else { return }
        paging = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            offset = CGFloat(-dir) * width
        } completion: {
            commit()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.offset = 0 }
            self.paging = false
        }
    }

    /// Nhả tay chưa đủ xa: bật về tuần hiện tại.
    func settle() { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 } }
}
