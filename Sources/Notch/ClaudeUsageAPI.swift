import AppKit
import Foundation
import Security
import SwiftUI

// Mức dùng Claude hỏi thẳng API (người dùng tự bật). Đọc access token Claude Code lưu trong Keychain,
// chỉ gửi tới api.anthropic.com. Không đụng refresh token, không ghi Keychain, không lưu hay in token.

private enum UsageFetch: Sendable {
    case success(five: ClaudeUsage.Limit?, seven: ClaudeUsage.Limit?, scoped: [ClaudeUsage.Scoped])
    case needsLogin
    case denied
    case failed(String)
}

@MainActor
final class ClaudeUsageAPI: ObservableObject {
    static let shared = ClaudeUsageAPI()

    enum Status: Equatable { case off, idle, loading, ok, needsLogin, denied, failed(String) }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            if enabled { status = .idle; interval = Self.base; kick(force: true) } else { stop(); status = .off; panelOpen = false }
        }
    }
    @Published private(set) var status: Status
    /// Bảng mức dùng đang mở dưới chip trên notch.
    @Published var panelOpen = false

    private static let key = "claude.usageAPI"
    private static let base: TimeInterval = 300
    private var demand = 0
    private var timer: Timer?
    private var interval = base
    private var inFlight = false
    private var lastFetch: Date?

    private init() {
        let on = UserDefaults.standard.bool(forKey: Self.key)
        enabled = on
        status = on ? .idle : .off
    }

    /// Có chỗ đang hiện mức dùng (chip, cánh notch, Cài đặt): chỉ hỏi API khi demand > 0.
    func retain() {
        demand += 1
        if demand == 1 { kick(force: false) }
    }

    func release() {
        demand = max(0, demand - 1)
        if demand == 0 { timer?.invalidate(); timer = nil }
    }

    func refreshNow() { kick(force: true) }

    private func kick(force: Bool) {
        guard enabled, demand > 0 || force else { return }
        let age = Date().timeIntervalSince(lastFetch ?? .distantPast)
        if force || age > Self.base { fetch() } else { scheduleNext(after: Self.base - age) }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNext(after delay: TimeInterval? = nil) {
        timer?.invalidate()
        timer = nil
        guard enabled, demand > 0 else { return }
        let t = Timer(timeInterval: max(delay ?? interval, 30), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fetch() {
        guard enabled, !inFlight else { return }
        inFlight = true
        if status != .ok { status = .loading }
        DispatchQueue.global(qos: .utility).async {
            Self.load { result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.finish(result) }
                }
            }
        }
    }

    private func finish(_ result: UsageFetch) {
        inFlight = false
        lastFetch = Date()
        guard enabled else { return }
        switch result {
        case let .success(five, seven, scoped):
            ClaudeUsage.shared.ingestAPI(fiveHour: five, sevenDay: seven, scoped: scoped)
            status = .ok
            interval = Self.base
        case .needsLogin:
            status = .needsLogin
            interval = 600
        case .denied:
            // Người dùng từ chối Keychain: không hỏi lại tự động, chờ bấm "Thử lại".
            status = .denied
            stop()
            return
        case let .failed(msg):
            status = .failed(msg)
            interval = min(interval * 2, 1800)
        }
        scheduleNext()
    }

    var statusText: String? {
        switch status {
        case .off, .idle, .ok: return nil
        case .loading: return L("Đang lấy số liệu…", "Fetching…")
        case .needsLogin: return L("Mở Claude Code để làm mới đăng nhập", "Open Claude Code to refresh the sign-in")
        case .denied: return L("Roost chưa được đọc Keychain. Bấm Thử lại rồi chọn Always Allow.", "Roost can't read the Keychain yet. Click Retry, then choose Always Allow.")
        case let .failed(msg): return msg
        }
    }

    // MARK: - Keychain + HTTP (chạy ngoài main thread)

    // Token giữ trong bộ nhớ tới khi hết hạn: không đọc Keychain mỗi lần lấy số liệu (mỗi lần đọc có thể hiện hộp thoại).
    nonisolated(unsafe) private static var cached: (token: String, exp: TimeInterval)?
    nonisolated private static let cacheLock = NSLock()

    private enum Read { case ok(Data), missing, denied }

    /// Đọc mục "Claude Code-credentials". Ưu tiên /usr/bin/security: Claude Code tạo mục này bằng chính công cụ đó nên
    /// nó nằm sẵn trong danh sách được phép, macOS không hỏi mật khẩu kể cả khi Roost vừa cập nhật (chữ ký ad-hoc đổi)
    /// hay Claude Code vừa ghi lại mục (danh sách "Always Allow" của Roost bị xoá). Lỗi lạ thì lùi về SecItem như cũ.
    nonisolated private static func readCredentials() -> Read {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            switch p.terminationStatus {
            case 0 where !data.isEmpty: return .ok(data)
            case 44: return .missing  // errSecItemNotFound
            default: break
            }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &item)
        if st == errSecUserCanceled || st == errSecAuthFailed || st == errSecInteractionNotAllowed { return .denied }
        guard st == errSecSuccess, let data = item as? Data else { return .missing }
        return .ok(data)
    }

    /// Token còn hạn ít nhất 60 giây: lấy từ bộ nhớ, hết thì đọc lại Keychain.
    nonisolated private static func token() -> (String?, denied: Bool) {
        let now = Date().timeIntervalSince1970
        cacheLock.lock()
        if let c = cached, c.exp > now + 60 { cacheLock.unlock(); return (c.token, false) }
        cached = nil
        cacheLock.unlock()
        switch readCredentials() {
        case .denied: return (nil, true)
        case .missing: return (nil, false)
        case let .ok(data):
            // security -w in ra chuỗi JSON kèm xuống dòng.
            guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let t = oauth["accessToken"] as? String, !t.isEmpty else { return (nil, false) }
            let exp = ((oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0) / 1000
            guard exp == 0 || exp > now + 60 else { return (nil, false) }
            cacheLock.lock(); cached = (t, exp == 0 ? now + 3600 : exp); cacheLock.unlock()
            return (t, false)
        }
    }

    nonisolated private static func forgetToken() { cacheLock.lock(); cached = nil; cacheLock.unlock() }

    nonisolated private static func load(_ done: @escaping @Sendable (UsageFetch) -> Void) {
        let (tok, denied) = token()
        if denied { done(.denied); return }
        guard let token = tok else { done(.needsLogin); return }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Roost", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        session.dataTask(with: req) { body, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let http = response as? HTTPURLResponse else {
                done(.failed(L("Không kết nối được", "Can't connect"))); return
            }
            switch http.statusCode {
            case 200: break
            case 401, 403:
                // Token trong bộ nhớ có thể đã bị Claude Code thay: lần sau đọc lại Keychain.
                forgetToken()
                done(.needsLogin); return
            case 429: done(.failed(L("Bị giới hạn tạm thời, thử lại sau", "Rate limited, will retry"))); return
            default: done(.failed(L("Lỗi máy chủ \(http.statusCode)", "Server error \(http.statusCode)"))); return
            }
            guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                done(.failed(L("Số liệu không đọc được", "Unreadable response"))); return
            }
            done(parse(json))
        }.resume()
    }

    nonisolated private static func parse(_ json: [String: Any]) -> UsageFetch {
        func window(_ any: Any?) -> ClaudeUsage.Limit? {
            guard let d = any as? [String: Any],
                  let used = (d["utilization"] as? NSNumber)?.doubleValue,
                  let reset = date(d["resets_at"]) else { return nil }
            return ClaudeUsage.Limit(usedPercent: min(max(used, 0), 100), resetsAt: reset)
        }
        var scoped: [ClaudeUsage.Scoped] = []
        for l in json["limits"] as? [[String: Any]] ?? [] where l["kind"] as? String == "weekly_scoped" {
            guard let pct = (l["percent"] as? NSNumber)?.doubleValue, let reset = date(l["resets_at"]),
                  let scope = l["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String else { continue }
            scoped.append(.init(name: name, limit: .init(usedPercent: min(max(pct, 0), 100), resetsAt: reset)))
        }
        let five = window(json["five_hour"]), seven = window(json["seven_day"])
        guard five != nil || seven != nil else { return .failed(L("Không có số liệu mức dùng", "No usage data")) }
        return .success(five: five, seven: seven, scoped: scoped)
    }

    /// "2026-11-15T11:09:59.645831+00:00": bỏ phần lẻ của giây rồi đọc ISO 8601.
    nonisolated private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

// MARK: - Notch: chip trên hàng tab + bảng mức dùng

/// Màu theo giao diện cho chip và bảng.
private struct UsageStyleSet {
    let bg: Color, border: Color, text: Color, secondary: Color, track: Color, radius: CGFloat

    static var current: UsageStyleSet {
        switch Theme.current {
        case .pixel:
            return .init(bg: Color(red: 0.08, green: 0.06, blue: 0.16), border: PixelPalette.border, text: .white,
                         secondary: PixelPalette.border.opacity(0.65), track: PixelPalette.dim.opacity(0.6), radius: 0)
        case .cassette:
            return .init(bg: CassettePalette.label, border: CassettePalette.line, text: CassettePalette.ink,
                         secondary: CassettePalette.faded, track: CassettePalette.ink.opacity(0.15), radius: 6)
        case .vangogh:
            return .init(bg: VG.night, border: VG.yellow.opacity(0.85), text: VG.cream,
                         secondary: VG.muted, track: VG.cream.opacity(0.18), radius: 12)
        case .standard:
            return .init(bg: Color(white: 0.1), border: .white.opacity(0.12), text: .white,
                         secondary: .white.opacity(0.55), track: .white.opacity(0.15), radius: 12)
        }
    }
}

/// Bảng mức dùng thả xuống dưới hàng tab: hai vòng lớn (5 giờ, tuần) có % ở giữa, thời gian tới lúc đặt lại,
/// hạn mức riêng từng model bên dưới, tuổi số liệu + nút làm mới ở góc.
struct ClaudeUsagePanel: View {
    @ObservedObject var api = ClaudeUsageAPI.shared
    @ObservedObject var usage = ClaudeUsage.shared
    @ObservedObject var extras = ClaudeExtras.shared

    var body: some View {
        let s = UsageStyleSet.current
        TimelineView(.everyMinute) { ctx in
            // Notch thấp: bỏ các hạn mức riêng từng model trước, để bảng không bị đáy notch cắt mất.
            ViewThatFits(in: .vertical) {
                content(s, now: ctx.date, scoped: true)
                content(s, now: ctx.date, scoped: false)
            }
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: s.radius).fill(s.bg))
        .overlay(RoundedRectangle(cornerRadius: s.radius).stroke(s.border, lineWidth: Theme.isPixel ? 2 : 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .onAppear { api.retain() }
        .onDisappear { api.release() }
    }

    @ViewBuilder private func content(_ s: UsageStyleSet, now: Date, scoped: Bool) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                    Text("Claude").font(.ui(13, weight: .bold)).foregroundStyle(s.text)
                    Text(extras.usageShow == .used ? L("phần đã dùng", "used") : L("phần còn lại", "left"))
                        .font(.ui(10)).foregroundStyle(s.secondary)
                    Spacer()
                    Button { api.refreshNow() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                            if api.status == .loading {
                                Text(L("đang lấy", "loading")).font(.ui(10))
                            } else if let at = usage.updatedAt {
                                Text(Self.age(at, now: now)).font(.ui(10).monospacedDigit())
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(s.track.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(s.secondary)
                    .help(api.status == .denied ? L("Thử lại", "Retry") : L("Làm mới", "Refresh"))
                    .opacity(api.enabled ? 1 : 0.4)
                    .disabled(!api.enabled)
                }
                HStack(spacing: 10) {
                    ForEach([ClaudeUsage.Window.fiveHour, .sevenDay], id: \.self) { w in
                        ringTile(w, s, now: now).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if scoped, !usage.scoped.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(usage.scoped) { sc in scopedRow(sc, s) }
                    }
                }
                // Trạng thái "đang lấy" đã hiện ở nút làm mới; dòng này chỉ cho lỗi cần bạn làm gì đó.
                if api.status != .loading, let note = api.statusText {
                    Text(note).font(.ui(10)).foregroundStyle(s.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !api.enabled {
                    Text(L("Bật \"Tự lấy số liệu\" trong Cài đặt › Claude Code để số liệu luôn mới.", "Turn on \"Fetch automatically\" in Settings › Claude Code to keep these numbers fresh."))
                        .font(.ui(10)).foregroundStyle(s.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
    }

    /// Vòng nhỏ có % ở giữa, tên hạn mức và thời gian tới lúc đặt lại nằm bên phải: thấp hơn kiểu vòng lớn xếp dọc.
    @ViewBuilder private func ringTile(_ w: ClaudeUsage.Window, _ s: UsageStyleSet, now: Date) -> some View {
        let l = usage.limit(w)
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(s.track, lineWidth: 4.5)
                if let l {
                    Circle().trim(from: 0, to: ClaudeUsage.fraction(l, show: extras.usageShow))
                        .stroke(ClaudeUsage.color(l), style: StrokeStyle(lineWidth: 4.5, lineCap: Theme.isPixel ? .butt : .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(l.map { "\(Int((ClaudeUsage.fraction($0, show: extras.usageShow) * 100).rounded()))%" } ?? "--")
                    .font(.ui(12, weight: .bold).monospacedDigit())
                    .foregroundStyle(l == nil ? s.secondary : s.text)
                    .minimumScaleFactor(0.7).lineLimit(1).padding(.horizontal, 5)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(w == .fiveHour ? L("5 giờ", "5 hours") : L("Tuần", "Weekly"))
                    .font(.ui(12, weight: .semibold)).foregroundStyle(s.text)
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                    Text(l.map { Self.until($0.resetsAt, now: now) } ?? "--")
                        .font(.ui(10).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(s.secondary)
            }
        }
        .help(l.map { ClaudeUsage.resetText($0.resetsAt, now: now) } ?? "")
    }

    private func scopedRow(_ sc: ClaudeUsage.Scoped, _ s: UsageStyleSet) -> some View {
        let pct = Int((ClaudeUsage.fraction(sc.limit, show: extras.usageShow) * 100).rounded())
        return HStack(spacing: 8) {
            UsageGauge(limit: sc.limit, style: .ring, show: extras.usageShow, size: 14, lineWidth: 2.5, track: s.track)
            Text(L("Tuần, riêng \(sc.name)", "Weekly, \(sc.name) only")).font(.ui(11)).foregroundStyle(s.text).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(pct)%").font(.ui(11, weight: .semibold).monospacedDigit()).foregroundStyle(ClaudeUsage.color(sc.limit))
        }
    }

    /// "1 giờ 46 phút" / "2 ngày 8 giờ" tới lúc đặt lại.
    static func until(_ date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return L("đã đặt lại", "reset") }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return L("\(d) ngày \(h) giờ", "\(d)d \(h)h") }
        if h > 0 { return L("\(h) giờ \(m) phút", "\(h)h \(m)m") }
        return L("\(max(m, 1)) phút", "\(max(m, 1))m")
    }

    /// Tuổi số liệu: "vừa xong", "6 phút", "2 giờ".
    static func age(_ date: Date, now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(date)) / 60)
        if m < 1 { return L("vừa xong", "now") }
        if m < 60 { return L("\(m) phút", "\(m)m") }
        return L("\(m / 60) giờ", "\(m / 60)h")
    }
}

/// Chỉ dựng bảng khi đang mở (để retain/release đúng lúc).
struct ClaudeUsagePanelHost: View {
    @ObservedObject var api = ClaudeUsageAPI.shared

    var body: some View {
        if api.panelOpen {
            ClaudeUsagePanel()
                .padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
    }
}
