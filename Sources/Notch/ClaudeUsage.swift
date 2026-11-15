import AppKit
import SwiftUI

// MARK: - Cài đặt Claude (âm báo + mức dùng)

/// Cài đặt riêng cho âm báo và mức dùng của Claude (tách khỏi SettingsStore cho gọn).
@MainActor
final class ClaudeExtras: ObservableObject {
    static let shared = ClaudeExtras()

    enum UsageStyle: String, CaseIterable, Identifiable {
        case ring, bar
        var id: String { rawValue }
        var title: String { self == .ring ? L("Vòng", "Ring") : L("Thanh", "Bar") }
    }

    enum UsageShow: String, CaseIterable, Identifiable {
        case used, remaining
        var id: String { rawValue }
        var title: String { self == .used ? L("Phần đã dùng", "Used") : L("Phần còn lại", "Remaining") }
    }

    /// Âm báo khi Claude xin quyền, hỏi, hoặc đang chờ bạn.
    @Published var sound: Bool { didSet { save(sound, "claude.sound") } }
    @Published var soundName: String { didSet { save(soundName, "claude.soundName") } }
    @Published var usageStyle: UsageStyle { didSet { save(usageStyle.rawValue, "claude.usageStyle") } }
    @Published var usageShow: UsageShow { didSet { save(usageShow.rawValue, "claude.usageShow") } }
    /// Báo trên notch khi hạn mức 5 giờ / tuần được đặt lại.
    @Published var resetNotice: Bool { didSet { save(resetNotice, "claude.resetNotice") } }

    /// Âm thanh có sẵn của macOS, xếp từ nhẹ tới rõ.
    static let sounds = ["Tink", "Pop", "Purr", "Glass", "Ping", "Morse", "Hero", "Submarine"]

    private init() {
        let d = UserDefaults.standard
        sound = d.object(forKey: "claude.sound") as? Bool ?? true
        soundName = d.string(forKey: "claude.soundName") ?? "Tink"
        usageStyle = UsageStyle(rawValue: d.string(forKey: "claude.usageStyle") ?? "") ?? .ring
        usageShow = UsageShow(rawValue: d.string(forKey: "claude.usageShow") ?? "") ?? .used
        resetNotice = d.object(forKey: "claude.resetNotice") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    /// Phát âm báo (bỏ qua khi tắt). Gọi dồn trong 1 giây chỉ kêu một lần.
    func playSound() {
        guard sound, Date().timeIntervalSince(lastSound) > 1 else { return }
        lastSound = Date()
        NSSound(named: NSSound.Name(soundName))?.play()
    }
    private var lastSound = Date.distantPast
}

// MARK: - Thông báo nhanh từ Claude

/// Nội dung peek của Claude: phiên đang chờ bạn, hoặc hạn mức vừa được đặt lại.
struct ClaudeNotice: Equatable {
    enum Kind: Equatable { case waiting, reset }
    let kind: Kind
    /// Bên trái: tên project, hoặc "5 giờ" / "Tuần".
    let title: String
    /// Bên phải: trạng thái ngắn.
    let status: String

    static func waiting(project: String) -> ClaudeNotice {
        ClaudeNotice(kind: .waiting, title: project.isEmpty ? "Claude" : project,
                     status: L("Đang chờ bạn", "Needs you"))
    }

    static func reset(_ window: ClaudeUsage.Window) -> ClaudeNotice {
        ClaudeNotice(kind: .reset, title: window.title, status: L("Đã đặt lại", "Reset"))
    }
}

/// Hai cánh của peek Claude: icon + tên project bên trái, trạng thái bên phải.
struct ClaudeNoticeWings: View {
    let notice: ClaudeNotice
    let wing: CGFloat

    private var tint: Color {
        notice.kind == .reset ? Color(red: 0.30, green: 0.85, blue: 0.40) : Color(red: 0.85, green: 0.47, blue: 0.34)
    }

    var body: some View {
        let cassette = Theme.isCassette
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: notice.kind == .reset ? "arrow.counterclockwise.circle.fill" : "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(notice.title)
                    .font(cassette ? .hand(13) : .ui(11, weight: .semibold))
                    .foregroundStyle(cassette ? CassettePalette.ink : .white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, cassette ? 6 : 0)
            .padding(.vertical, cassette ? 2 : 0)
            .background(cassette ? CassettePalette.note : Color.clear)
            .frame(width: wing - 8)
            .padding(.leading, 8)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(notice.status)
                    .font(cassette ? .hand(13) : .ui(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(width: wing)
        }
    }
}

// MARK: - Mức dùng (nguồn: statusline của Claude Code)

/// Mức dùng gói Claude theo cửa sổ 5 giờ và theo tuần.
/// Nguồn: trường `rate_limits` trong JSON mà Claude Code đưa cho lệnh statusline
/// (`roost-hook --statusline` chuyển tiếp qua socket). Chỉ có với gói Pro/Max, sau lần gọi API đầu tiên.
@MainActor
final class ClaudeUsage: ObservableObject {
    static let shared = ClaudeUsage()

    enum Window: String, Codable { case fiveHour, sevenDay
        var title: String { self == .fiveHour ? L("Giới hạn 5 giờ", "5-hour limit") : L("Giới hạn tuần", "Weekly limit") }
        var short: String { self == .fiveHour ? "5h" : "7d" }
    }

    struct Limit: Codable, Equatable {
        var usedPercent: Double
        var resetsAt: Date
    }

    @Published private(set) var fiveHour: Limit?
    @Published private(set) var sevenDay: Limit?
    @Published private(set) var updatedAt: Date?
    /// Hạn mức tuần riêng theo model (chỉ có từ API), vd. "Fable".
    @Published private(set) var scoped: [Scoped] = []

    struct Scoped: Codable, Equatable, Identifiable {
        var name: String
        var limit: Limit
        var id: String { name }
    }

    /// Gọi khi một hạn mức qua mốc đặt lại (đang có dùng).
    var onReset: ((Window) -> Void)?

    private var timers: [Window: Timer] = [:]
    private let key = "claude.usage.v1"

    private struct Stored: Codable { var fiveHour: Limit?; var sevenDay: Limit?; var updatedAt: Date?; var scoped: [Scoped]? }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            fiveHour = s.fiveHour
            sevenDay = s.sevenDay
            updatedAt = s.updatedAt
            scoped = s.scoped ?? []
        }
        expireOld()
        schedule()
    }

    var hasData: Bool { fiveHour != nil || sevenDay != nil }

    func limit(_ w: Window) -> Limit? { w == .fiveHour ? fiveHour : sevenDay }

    /// Nhận `rate_limits` từ statusline. Bỏ qua dữ liệu hỏng.
    func ingest(_ rateLimits: [String: Any]) {
        func parse(_ any: Any?) -> Limit? {
            guard let d = any as? [String: Any],
                  let used = (d["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (d["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return Limit(usedPercent: min(max(used, 0), 100), resetsAt: Date(timeIntervalSince1970: reset))
        }
        let five = parse(rateLimits["five_hour"])
        let seven = parse(rateLimits["seven_day"])
        guard five != nil || seven != nil else { return }
        // Statusline chạy sau mỗi tin nhắn: chỉ phát thay đổi khi số liệu đổi (hoặc mỗi phút cho "cập nhật lúc").
        let changed = (five != nil && five != fiveHour) || (seven != nil && seven != sevenDay)
        guard changed || Date().timeIntervalSince(updatedAt ?? .distantPast) > 60 else { return }
        if let five, five != fiveHour { fiveHour = five }
        if let seven, seven != sevenDay { sevenDay = seven }
        updatedAt = Date()
        persist()
        if changed { schedule() }
    }

    /// Nhận kết quả từ API mức dùng (ClaudeUsageAPI). Mới nhất thắng, như statusline.
    func ingestAPI(fiveHour five: Limit?, sevenDay seven: Limit?, scoped extra: [Scoped]) {
        guard five != nil || seven != nil else { return }
        let changed = five != fiveHour || seven != sevenDay
        if let five { fiveHour = five }
        if let seven { sevenDay = seven }
        if extra != scoped { scoped = extra }
        updatedAt = Date()
        persist()
        if changed { schedule() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt, scoped: scoped)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Mốc đặt lại đã qua khi app tắt: coi như về 0, không báo.
    private func expireOld() {
        let now = Date()
        if let f = fiveHour, f.resetsAt <= now { fiveHour = Limit(usedPercent: 0, resetsAt: f.resetsAt) }
        if let s = sevenDay, s.resetsAt <= now { sevenDay = Limit(usedPercent: 0, resetsAt: s.resetsAt) }
    }

    /// Một timer một lần cho mỗi mốc đặt lại (không poll).
    private func schedule() {
        for w in [Window.fiveHour, .sevenDay] {
            timers[w]?.invalidate()
            timers[w] = nil
            guard let l = limit(w), l.usedPercent > 0, l.resetsAt > Date() else { continue }
            let t = Timer(fire: l.resetsAt.addingTimeInterval(2), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.didReset(w) }
            }
            t.tolerance = 30
            RunLoop.main.add(t, forMode: .common)
            timers[w] = t
        }
    }

    private func didReset(_ w: Window) {
        guard let l = limit(w), l.resetsAt <= Date().addingTimeInterval(5) else { return }
        let zero = Limit(usedPercent: 0, resetsAt: l.resetsAt)
        if w == .fiveHour { fiveHour = zero } else { sevenDay = zero }
        persist()
        timers[w] = nil
        if ClaudeExtras.shared.resetNotice { onReset?(w) }
    }

    /// Tỉ lệ cần vẽ (0…1) theo cài đặt đã dùng / còn lại.
    static func fraction(_ l: Limit, show: ClaudeExtras.UsageShow) -> Double {
        let used = l.usedPercent / 100
        return show == .used ? used : 1 - used
    }

    /// Màu theo phần đã dùng: dưới 70% êm (xanh), 70–90% cảnh báo (vàng cam), từ 90% đỏ.
    static func color(_ l: Limit) -> Color {
        l.usedPercent >= 90 ? Color(red: 1, green: 0.33, blue: 0.27)
            : l.usedPercent >= 70 ? Color(red: 1, green: 0.74, blue: 0.2)
            : Color(red: 0.36, green: 0.8, blue: 0.56)
    }

    static func resetText(_ date: Date, now: Date = Date()) -> String {
        let s = date.timeIntervalSince(now)
        if s <= 0 { return L("đã đặt lại", "reset") }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 {
            let f = DateFormatter()
            f.dateFormat = Lang.isVietnamese ? "EEEE HH:mm" : "EEE HH:mm"
            f.locale = Locale(identifier: Lang.isVietnamese ? "vi_VN" : "en_US")
            return L("đặt lại \(f.string(from: date))", "resets \(f.string(from: date))")
        }
        return h > 0 ? L("đặt lại sau \(h) giờ \(m) phút", "resets in \(h)h \(m)m")
                     : L("đặt lại sau \(m) phút", "resets in \(m)m")
    }
}

// MARK: - Hình vẽ mức dùng

/// Vòng hoặc thanh cho một hạn mức. Màu chuyển cam → vàng → đỏ theo mức đã dùng.
struct UsageGauge: View {
    let limit: ClaudeUsage.Limit
    let style: ClaudeExtras.UsageStyle
    let show: ClaudeExtras.UsageShow
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5
    /// Nền vòng / thanh: trắng mờ trên notch đen, xám trên cửa sổ Cài đặt.
    var track: Color = .white.opacity(0.18)

    var body: some View {
        let f = ClaudeUsage.fraction(limit, show: show)
        let c = ClaudeUsage.color(limit)
        if style == .ring {
            ZStack {
                Circle().stroke(track, lineWidth: lineWidth)
                Circle().trim(from: 0, to: f)
                    .stroke(c, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
        } else {
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(c).frame(width: max(lineWidth, size * 2 * f))
            }
            .frame(width: size * 2, height: lineWidth + 1)
        }
    }
}

/// Cánh notch lúc thu gọn: vòng / thanh 5 giờ (và tuần nếu còn chỗ) kèm phần trăm.
struct ClaudeUsageWing: View {
    @ObservedObject var usage = ClaudeUsage.shared
    @ObservedObject var extras = ClaudeExtras.shared

    var body: some View {
        if let l = usage.fiveHour ?? usage.sevenDay {
            let pct = Int((ClaudeUsage.fraction(l, show: extras.usageShow) * 100).rounded())
            HStack(spacing: 4) {
                UsageGauge(limit: l, style: extras.usageStyle, show: extras.usageShow, size: extras.usageStyle == .ring ? 13 : 9, lineWidth: 2.2)
                Text("\(pct)%")
                    .font(.ui(11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .help(L("Mức dùng Claude: \(Int(l.usedPercent))% đã dùng", "Claude usage: \(Int(l.usedPercent))% used"))
            .onAppear { ClaudeUsageAPI.shared.retain() }
            .onDisappear { ClaudeUsageAPI.shared.release() }
        }
    }
}

/// Khối mức dùng đầy đủ (Cài đặt › Claude): 2 hạn mức, thời gian đặt lại.
struct ClaudeUsageRows: View {
    @ObservedObject var usage = ClaudeUsage.shared
    @ObservedObject var extras = ClaudeExtras.shared
    @ObservedObject var settings = SettingsStore.shared   // dựng lại khi đổi ngôn ngữ

    var body: some View {
        Group { content }
            .onAppear { ClaudeUsageAPI.shared.retain() }
            .onDisappear { ClaudeUsageAPI.shared.release() }
    }

    @ViewBuilder private var content: some View {
        if usage.hasData {
            ForEach([ClaudeUsage.Window.fiveHour, .sevenDay], id: \.self) { w in
                if let l = usage.limit(w) {
                    HStack(spacing: 10) {
                        UsageGauge(limit: l, style: extras.usageStyle, show: extras.usageShow, size: 20, lineWidth: 3,
                                   track: Color.secondary.opacity(0.25))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.title).font(.callout.weight(.medium))
                            Text(ClaudeUsage.resetText(l.resetsAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let pct = Int((ClaudeUsage.fraction(l, show: extras.usageShow) * 100).rounded())
                        Text(extras.usageShow == .used ? L("đã dùng \(pct)%", "\(pct)% used") : L("còn \(pct)%", "\(pct)% left"))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(usage.scoped) { sc in
                HStack(spacing: 10) {
                    UsageGauge(limit: sc.limit, style: extras.usageStyle, show: extras.usageShow, size: 20, lineWidth: 3,
                               track: Color.secondary.opacity(0.25))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Tuần, riêng \(sc.name)", "Weekly, \(sc.name) only")).font(.callout.weight(.medium))
                        Text(ClaudeUsage.resetText(sc.limit.resetsAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let pct = Int((ClaudeUsage.fraction(sc.limit, show: extras.usageShow) * 100).rounded())
                    Text(extras.usageShow == .used ? L("đã dùng \(pct)%", "\(pct)% used") : L("còn \(pct)%", "\(pct)% left"))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let at = usage.updatedAt {
                Text(L("Cập nhật lần cuối \(at.formatted(date: .omitted, time: .shortened))", "Last updated \(at.formatted(date: .omitted, time: .shortened))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(L("Chưa có số liệu. Bật \"Tự lấy số liệu\" bên dưới, hoặc cài statusLine rồi gửi một tin nhắn trong Claude Code ở Terminal. Chỉ có với gói Pro, Max hoặc Team.", "No data yet. Turn on \"Fetch automatically\" below, or set up the statusLine and send one message in Claude Code in Terminal. Only on Pro, Max or Team plans."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
