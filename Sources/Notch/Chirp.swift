import AppKit
import SwiftUI

struct ChirpCard: Codable, Identifiable, Equatable {
    let cardId: Int
    let due: String?
    let lemma: String
    let ipa: String?
    let meaningVi: String
    let sentence: String?
    let stageLabel: String?
    let hard: Bool?
    var id: Int { cardId }
}

/// Một lần Nhớ/Quên chờ gửi (giữ `reviewedAt` để gửi muộn vẫn đúng giờ ôn).
struct ChirpResult: Codable, Equatable {
    let cardId: Int
    let remembered: Bool
    let reviewedAt: String
    let seconds: Int?
}

struct ChirpSummary: Codable, Equatable {
    var due: Int
    var streak: Int
}

/// Kết nối Chirp (ôn từ vựng): địa chỉ trong UserDefaults, token `chirp_…` trong Keychain.
/// Thẻ cần ôn + hàng đợi kết quả lưu ở Application Support/Roost/chirp.json để mất mạng vẫn ôn được.
@MainActor
final class ChirpClient: ObservableObject {
    static let shared = ChirpClient()
    static let tokenService = "io.github.letoan1.roost.chirp"
    static let defaultURL = "https://chirp-two-bay.vercel.app"
    static let syncEvery: TimeInterval = 30 * 60

    enum Status: Equatable { case unknown, checking, connected, failed(String) }

    @Published var baseURL: String = UserDefaults.standard.string(forKey: "chirp.url") ?? ChirpClient.defaultURL {
        didSet { UserDefaults.standard.set(baseURL, forKey: "chirp.url"); status = .unknown }
    }
    /// Cờ trong UserDefaults để lúc mở app không phải đọc Keychain (hộp thoại Keychain chặn main thread).
    @Published private(set) var hasToken: Bool = UserDefaults.standard.object(forKey: "chirp.hasToken") as? Bool
        ?? !(Keychain.read(ChirpClient.tokenService) ?? "").isEmpty
    @Published private(set) var status: Status = .unknown
    @Published private(set) var summary: ChirpSummary?
    @Published private(set) var cards: [ChirpCard] = []
    @Published private(set) var queue: [ChirpResult] = []
    /// Màn ôn thẻ đang thay nội dung notch (nút Chirp trong Bố cục notch).
    @Published var panelOpen = false

    private var tokenCache: String?
    private var timer: Timer?
    private var syncing = false
    private var lastSync: Date?

    private init() { load() }

    // MARK: Token

    func setToken(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(Self.tokenService, v)
        tokenCache = v
        setHasToken(!v.isEmpty)
        status = .unknown
    }

    func disconnect() {
        Keychain.write(Self.tokenService, "")
        tokenCache = ""
        setHasToken(false)
        status = .unknown
        summary = nil
        cards = []
        panelOpen = false
        timer?.invalidate()
        save()
    }

    private func setHasToken(_ v: Bool) {
        hasToken = v
        UserDefaults.standard.set(v, forKey: "chirp.hasToken")
    }

    func checkConnection() async {
        status = .checking
        await sync(force: true)
        if status == .checking { status = .unknown }   // đang đồng bộ dở từ trước
    }

    // MARK: Đồng bộ

    /// Gửi hàng đợi, lấy status + thẻ, hẹn lần sau. Chỉ chạy khi có token.
    func sync(force: Bool = false) async {
        guard hasToken, !syncing else { return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 120 { return }
        syncing = true
        defer { syncing = false; scheduleNext() }
        await flush()
        do {
            summary = try JSONDecoder().decode(ChirpSummary.self, from: try await send("GET", "/api/roost/status"))
            struct Cards: Decodable { let cards: [ChirpCard] }
            let fresh = try JSONDecoder().decode(Cards.self, from: try await send("GET", "/api/roost/cards?limit=20")).cards
            let pending = Set(queue.map(\.cardId))
            cards = fresh.filter { !pending.contains($0.cardId) }
            lastSync = Date()
            status = .connected
            save()
        } catch {
            status = .failed(Self.message(error))
        }
    }

    /// Mạng vừa có lại: gửi các kết quả còn đợi.
    func networkBack() {
        guard hasToken else { return }
        Task { await sync(force: !queue.isEmpty) }
    }

    /// Một hẹn giờ 30 phút (không chạy liên tục), chỉ khi có token.
    private func scheduleNext() {
        timer?.invalidate()
        guard hasToken else { return }
        let t = Timer(timeInterval: Self.syncEvery, repeats: false) { _ in
            MainActor.assumeIsolated { Task { await ChirpClient.shared.sync(force: true) } }
        }
        t.tolerance = 120
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func answer(_ card: ChirpCard, remembered: Bool, seconds: Int?) {
        queue.append(ChirpResult(cardId: card.cardId, remembered: remembered,
                                 reviewedAt: ISO8601DateFormatter().string(from: Date()), seconds: seconds))
        cards.removeAll { $0.cardId == card.cardId }
        if var s = summary, s.due > 0 { s.due -= 1; summary = s }
        save()
        Task { await flush() }
    }

    /// Gửi tối đa 100 kết quả mỗi lần; chỉ bỏ khỏi hàng đợi những kết quả Chirp trả ok=true.
    private func flush() async {
        while !queue.isEmpty {
            let batch = Array(queue.prefix(100))
            struct Reply: Decodable { struct R: Decodable { let cardId: Int; let ok: Bool }; let results: [R] }
            guard let data = try? await send("POST", "/api/roost/review", json: ["results": batch.map(Self.json)]),
                  let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
            let ok = Set(reply.results.filter(\.ok).map(\.cardId))
            let sent = batch.filter { ok.contains($0.cardId) }
            guard !sent.isEmpty else { return }   // không kết quả nào được nhận: đợi lần sau
            queue.removeAll { r in sent.contains(r) }
            save()
        }
    }

    private static func json(_ r: ChirpResult) -> [String: Any] {
        var d: [String: Any] = ["cardId": r.cardId, "remembered": r.remembered, "reviewedAt": r.reviewedAt]
        if let s = r.seconds { d["seconds"] = s }
        return d
    }

    // MARK: Lưu trên máy

    private struct Offline: Codable { var summary: ChirpSummary?; var cards: [ChirpCard]; var queue: [ChirpResult] }

    private static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Roost/chirp.json")

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let o = try? JSONDecoder().decode(Offline.self, from: data) else { return }
        summary = o.summary
        cards = o.cards
        queue = o.queue
    }

    private func save() {
        let o = Offline(summary: summary, cards: cards, queue: queue)
        guard let data = try? JSONEncoder().encode(o) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    // MARK: Gọi API

    struct ChirpError: Error { let message: String }

    private static func message(_ error: Error) -> String {
        (error as? ChirpError)?.message
            ?? L("Không kết nối được tới Chirp, kiểm tra địa chỉ và mạng.", "Couldn't reach Chirp, check the address and network.")
    }

    /// Gọi API Chirp với `Authorization: Bearer <token>`, trả về dữ liệu phản hồi.
    func send(_ method: String, _ path: String, json: Any? = nil) async throws -> Data {
        if tokenCache == nil { tokenCache = Keychain.read(Self.tokenService) ?? "" }
        guard let token = tokenCache, !token.isEmpty else {
            throw ChirpError(message: L("Chưa có token.", "No token yet."))
        }
        guard let url = Self.endpoint(baseURL, path) else {
            throw ChirpError(message: L("Địa chỉ phải bắt đầu bằng https://", "The address must start with https://"))
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            throw ChirpError(message: L("Token không đúng hoặc đã bị thu hồi.", "The token is wrong or was revoked."))
        }
        guard (200..<300).contains(code) else {
            throw ChirpError(message: L("Chirp trả về lỗi \(code).", "Chirp returned error \(code)."))
        }
        return data
    }

    /// Chỉ https (http chỉ cho máy mình) để token không đi qua mạng dạng chữ thường.
    nonisolated static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path), let host = url.host, !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        return url.scheme == "https" || (url.scheme == "http" && local) ? url : nil
    }

    static func streakText(_ n: Int) -> String {
        switch n {
        case ..<1: return L("Bắt đầu chuỗi ngày", "Start your streak")
        case 1: return L("Ngày đầu tiên", "Day one")
        default: return L("\(n) ngày liền", "\(n)-day streak")
        }
    }

    func toggle() {
        withAnimation(.easeOut(duration: 0.2)) {
            panelOpen.toggle()
            if panelOpen { VietQRStore.shared.panelOpen = false }
        }
        if panelOpen { Task { await sync() } }
    }
}

// MARK: - Notch

/// Màn ôn thẻ trong notch: từ, phiên âm, câu ví dụ; bấm thẻ để lật xem nghĩa rồi chọn Nhớ / Quên.
struct ChirpReviewPanel: View {
    @ObservedObject var chirp = ChirpClient.shared
    private var flipped = State(initialValue: false)
    private var shownAt = State(initialValue: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bird.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                Text(L("Ôn từ", "Review")).font(.ui(11.5, weight: .semibold)).foregroundStyle(.white)
                if !chirp.cards.isEmpty {
                    Text(L("còn \(chirp.cards.count) thẻ", "\(chirp.cards.count) left"))
                        .font(.ui(10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if let s = chirp.summary {
                    Label(ChirpClient.streakText(s.streak), systemImage: "flame.fill")
                        .font(.ui(10.5, weight: .medium)).foregroundStyle(.orange.opacity(0.9))
                }
            }
            if !chirp.hasToken {
                empty(L("Chưa kết nối Chirp.", "Chirp isn't connected."), setup: true)
            } else if let card = chirp.cards.first {
                cardView(card)
            } else {
                empty(chirp.queue.isEmpty ? L("Hết thẻ cần ôn. Giỏi lắm!", "No cards due. Nice work!")
                      : L("Hết thẻ. \(chirp.queue.count) kết quả sẽ gửi khi có mạng.",
                          "All done. \(chirp.queue.count) results will be sent when you're online."), setup: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: chirp.cards.first?.cardId) { _, _ in
            flipped.wrappedValue = false
            shownAt.wrappedValue = Date()
        }
    }

    private func cardView(_ card: ChirpCard) -> some View {
        VStack(spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.18)) { flipped.wrappedValue.toggle() } } label: {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(card.lemma).font(.ui(20, weight: .bold)).foregroundStyle(.white)
                        if let ipa = card.ipa, !ipa.isEmpty {
                            Text(ipa).font(.ui(11.5)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    if flipped.wrappedValue {
                        Text(card.meaningVi).font(.ui(13, weight: .semibold)).foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    if let s = card.sentence, !s.isEmpty {
                        Text(s).font(.ui(11).italic()).foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                    if !flipped.wrappedValue {
                        Text(L("Bấm để xem nghĩa", "Click to see the meaning"))
                            .font(.ui(10)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            if flipped.wrappedValue {
                HStack(spacing: 8) {
                    choice(L("Quên", "Forgot"), color: Color(red: 1, green: 0.4, blue: 0.35)) { answer(card, false) }
                    choice(L("Nhớ", "Remembered"), color: Color(red: 0.3, green: 0.85, blue: 0.45)) { answer(card, true) }
                }
            }
        }
    }

    private func answer(_ card: ChirpCard, _ remembered: Bool) {
        let seconds = Int(Date().timeIntervalSince(shownAt.wrappedValue))
        withAnimation(.easeOut(duration: 0.18)) { chirp.answer(card, remembered: remembered, seconds: seconds) }
    }

    private func choice(_ title: String, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(12, weight: .bold)).foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Capsule().fill(color))
        }
        .buttonStyle(.plain)
    }

    private func empty(_ text: String, setup: Bool) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.ui(12)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            if setup {
                Button { SettingsWindowController.shared.show(pane: "chirp") } label: {
                    Text(L("Thiết lập", "Set up")).font(.ui(11, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 14)
    }
}

/// Cánh notch: số thẻ đến hạn + chuỗi ngày.
struct ChirpWing: View {
    @ObservedObject var chirp = ChirpClient.shared

    var body: some View {
        if let s = chirp.summary {
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 8, weight: .semibold))
                    Text("\(s.due)").font(.ui(11, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.85))
                if s.streak > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill").font(.system(size: 8, weight: .semibold))
                        Text("\(s.streak)").font(.ui(11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.orange)
                }
            }
            .help(L("Chirp: \(s.due) thẻ đến hạn, \(ChirpClient.streakText(s.streak))",
                    "Chirp: \(s.due) cards due, \(ChirpClient.streakText(s.streak))"))
        }
    }
}

// MARK: - Cài đặt

/// Cài đặt › Chirp: địa chỉ, token, kiểm tra và ngắt kết nối.
struct ChirpPane: View {
    @ObservedObject var chirp = ChirpClient.shared
    private var url = State(initialValue: ChirpClient.shared.baseURL)
    private var token = State(initialValue: Keychain.read(ChirpClient.tokenService) ?? "")

    var body: some View {
        SPage {
            SSection(L("Kết nối Chirp", "Chirp connection"),
                     note: L("Roost dùng token để lấy thẻ cần ôn và gửi kết quả Nhớ/Quên về Chirp, 30 phút đồng bộ một lần. Thẻ được lưu sẵn trên máy để mất mạng vẫn ôn được. Token lưu trong Keychain, chỉ gửi tới địa chỉ Chirp ở trên.",
                             "Roost uses the token to fetch cards to review and send Remember/Forget results back to Chirp, syncing every 30 minutes. Cards are kept on this Mac so you can review offline. The token stays in the Keychain and is only sent to the Chirp address above.")) {
                SRow("globe", L("Địa chỉ Chirp", "Chirp address"), divider: false) {
                    STextField(ChirpClient.defaultURL, text: url.projectedValue, width: 260)
                        .onChange(of: url.wrappedValue) { _, v in chirp.baseURL = v }
                }
                SRow("key", L("Token", "Token"), detail: L("Dạng chirp_…, lấy trong Cài đặt của Chirp.", "Looks like chirp_…, from Chirp's settings.")) {
                    STextField("chirp_…", text: token.projectedValue, secure: true, width: 260)
                        .onChange(of: token.wrappedValue) { _, v in chirp.setToken(v) }
                }
                SRow("antenna.radiowaves.left.and.right", L("Trạng thái", "Status"), detail: statusText) {
                    HStack(spacing: 8) {
                        Button(L("Ngắt kết nối", "Disconnect"), role: .destructive) {
                            chirp.disconnect()
                            token.wrappedValue = ""
                        }
                        .buttonStyle(SButtonStyle(.secondary))
                        .disabled(!chirp.hasToken)
                        Button(L("Kiểm tra kết nối", "Test connection")) { Task { await chirp.checkConnection() } }
                            .buttonStyle(SButtonStyle(.primary))
                            .disabled(!chirp.hasToken || chirp.status == .checking)
                    }
                }
            }
        }
    }

    private var statusText: String {
        if !chirp.hasToken { return L("Chưa kết nối.", "Not connected.") }
        switch chirp.status {
        case .unknown: return L("Đã có token, chưa kiểm tra.", "Token saved, not tested yet.")
        case .checking: return L("Đang kiểm tra…", "Testing…")
        case .connected:
            let s = chirp.summary.map { L(" \($0.due) thẻ đến hạn, \(ChirpClient.streakText($0.streak).lowercased()).",
                                          " \($0.due) cards due, \(ChirpClient.streakText($0.streak).lowercased()).") } ?? ""
            return L("Đã kết nối tới Chirp.", "Connected to Chirp.") + s
        case .failed(let m): return m
        }
    }
}
