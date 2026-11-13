import AppKit
import EventKit
import SwiftUI

@MainActor
final class CalendarStore: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: Color
        let meeting: Meeting?
    }

    struct Meeting {
        let url: URL
        let provider: String
    }

    private static let meetingPattern =
        #"https://(meet\.google\.com/[a-z0-9-]+|[a-z0-9.-]*zoom\.us/j/[^\s<>"']+|teams\.microsoft\.com/l/meetup-join/[^\s<>"']+)"#

    /// Tìm link họp trong url / location / notes của sự kiện (Google Calendar hay để ở notes).
    private static func meeting(in event: EKEvent) -> Meeting? {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in fields {
            guard let range = text.range(of: meetingPattern, options: [.regularExpression, .caseInsensitive]),
                  let url = URL(string: String(text[range]))
            else { continue }
            let host = url.host ?? ""
            let provider = host.contains("zoom") ? "Zoom" : host.contains("teams") ? "Teams" : "Meet"
            return Meeting(url: url, provider: provider)
        }
        return nil
    }

    @Published private(set) var access: Access
    /// Mọi sự kiện trong dải 7 ngày.
    @Published private(set) var windowEvents: [Item] = []
    /// Các ngày (startOfDay) trong dải 7 ngày có ít nhất 1 sự kiện.
    @Published private(set) var busyDays: Set<Date> = []
    /// Ngày đang xem (startOfDay), mặc định hôm nay.
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Lệch bao nhiêu tuần so với tuần chứa hôm nay.
    @Published private(set) var weekOffset = 0

    func shiftWeek(_ delta: Int) {
        weekOffset += delta
        // Dải 7 ngày mới không giao dải cũ → chọn hôm nay nếu quay về, không thì ngày giữa dải.
        selectedDay = weekOffset == 0 ? Calendar.current.startOfDay(for: Date()) : weekDays[3]
        reload()
    }

    /// "Tháng 11, 2026" theo ngày đang chọn.
    var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "'Tháng' M, yyyy"
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

    func resetToToday() {
        if weekOffset != 0 {
            shiftWeek(-weekOffset)
        } else {
            selectedDay = Calendar.current.startOfDay(for: Date())
        }
    }

    private let store = EKEventStore()
    private var timer: Timer?

    init() {
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Cập nhật khi sự kiện kết thúc / sang ngày mới.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// Dải 7 ngày quanh tâm (hôm nay + weekOffset tuần): 3 ngày trước, tâm, 3 ngày sau.
    var weekDays: [Date] {
        let cal = Calendar.current
        let center = cal.date(byAdding: .day, value: 7 * weekOffset, to: cal.startOfDay(for: Date()))!
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
            windowEvents = []
            busyDays = []
            return
        }
        let cal = Calendar.current
        let windowEnd = cal.date(byAdding: .day, value: 1, to: last)!
        let events = store.events(matching: store.predicateForEvents(withStart: first, end: windowEnd, calendars: nil))

        // Sự kiện nhiều ngày đánh dấu mọi ngày nó phủ.
        busyDays = Set(days.filter { day in
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            return events.contains { $0.startDate < end && $0.endDate > day }
        })

        windowEvents = events
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map {
                Item(id: $0.eventIdentifier ?? UUID().uuidString,
                     title: $0.title ?? "(Không tiêu đề)",
                     start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                     color: Color(nsColor: $0.calendar?.color ?? .systemBlue),
                     meeting: Self.meeting(in: $0))
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
