import AppKit
import Combine
import CryptoKit
import SwiftUI

/// Một dòng lời có mốc thời gian (giây). Lời không có mốc thì mọi `time` = nil.
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
}

/// Lời bài hát: lấy từ LRCLIB (lrclib.net), lưu đệm trên đĩa, đồng bộ theo vị trí phát.
/// Chỉ chạy khi có giao diện lời đang hiện (`attach` / `detach`), nên lúc ẩn không tốn gì.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    enum Status: Equatable { case idle, loading, synced, plain, missing }

    /// Bật trong Cài đặt: cho phép gửi thông tin bài hát tới lrclib.net.
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "lyrics.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "lyrics.enabled"); refresh() }
    }
    /// Notch đang hiện lời thay cho trình phát.
    /// Karaoke (màn hình lời toàn màn hình): tô dần từng chữ, không đụng âm thanh. Không lưu: tự tắt khi rời màn hình lời.
    @Published var karaoke = false {
        didSet {
            guard karaoke != oldValue else { return }
            if !karaoke { vocalLevel = 1; leaveAIVocals() }
            // Nạp sẵn model (~5 s, ~200 MB) để lúc kéo thanh thì AI đã sẵn sàng; chưa kéo thì chưa có tap / chấm tím.
            else if AIVocalSeparator.installed { AIVocals.shared.set(true) }
        }
    }
    /// Mức giọng ca sĩ khi karaoke (1 = nguyên bản). Dưới 1 mới cần process tap: macOS hiện chấm tím suốt lúc đó.
    @Published var vocalLevel: Double = 1 {
        didSet { if vocalLevel != oldValue { pushVocal() } }
    }
    /// Giọng dẫn ở câu khó (KaraokeGuide): đang hạ giọng mà tới câu hát nhanh thì giọng ca sĩ hát nhỏ để dẫn.
    @Published var guideHard: Bool = UserDefaults.standard.object(forKey: "karaoke.guideHard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(guideHard, forKey: "karaoke.guideHard"); pushVocal() }
    }
    static let karaokeVocalLevel = 0.0   // phím V: tắt hẳn giọng; muốn nghe giọng dẫn thì kéo thanh lên
    /// Trễ của đường âm thanh (loa Bluetooth, đi qua Roost khi hạ giọng), đo lại mỗi lần đồng bộ.
    @Published private(set) var audioDelay: Double = 0
    /// Vị trí bài mà bạn đang thật sự nghe thấy.
    func heardPosition(_ track: Track, at date: Date) -> Double { track.position(at: date) - audioDelay }

    @Published var showInNotch: Bool = UserDefaults.standard.bool(forKey: "lyrics.inNotch") {
        didSet { UserDefaults.standard.set(showInNotch, forKey: "lyrics.inNotch") }
    }
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var status: Status = .idle
    /// Dòng đang hát (nil = chưa tới dòng đầu).
    @Published private(set) var current: Int? {
        didSet { if current != oldValue { pushVocal() } }
    }

    private weak var media: NowPlaying?
    private var trackSink: AnyCancellable?
    private var consumers = 0
    private var loadedKey: String?
    private var lineTimer: Timer?
    private var fetchTask: Task<Void, Never>?


    func bind(_ media: NowPlaying) {
        guard self.media !== media else { return }
        self.media = media
        trackSink = media.$track.receive(on: RunLoop.main).sink { [weak self] track in
            MainActor.assumeIsolated {
                self?.flushIfJumped(track)
                self?.refresh()
                // Đổi app phát (Spotify ↔ Music) khi đang bỏ giọng: bỏ giọng ở app mới, trả giọng cho app cũ.
                if let self, AIVocals.shared.state == .on, let app = track?.bundleID, SoundCenter.shared.karaokeApp != app {
                    self.pushVocal(force: true)
                }
            }
        }
    }

    /// Giao diện lời xuất hiện / biến mất.
    func attach() { consumers += 1; refresh() }
    func detach() {
        consumers = max(consumers - 1, 0)
        if consumers == 0 { lineTimer?.invalidate(); lineTimer = nil }
    }

    var track: Track? { media?.track }

    /// Đo lại độ trễ âm thanh và dòng đang hát (bật / tắt AI, đổi loa).
    func resync() { pushVocal(force: true); sync() }   // gắn / gỡ tap trước rồi mới đo độ trễ

    private var leavingAI = false
    /// Tắt Karaoke khi đang tách bằng AI: nhạc đang nghe trễ ~1,6 s so với Spotify. Lùi Spotify lại đúng chỗ đang nghe,
    /// phát nốt phần đệm ~0,25 s rồi mới gỡ tap, để bài chạy tiếp liền mạch (không nhảy cóc, không câm).
    private func leaveAIVocals() {
        guard AIVocals.shared.state == .on, SoundCenter.shared.karaokeApp != nil, let track, track.isPlaying else {
            AIVocals.shared.set(false); return
        }
        leavingAI = true
        media?.seek(max(track.position(at: Date()) - AIVocalSeparator.delaySeconds - 0.25, 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.leavingAI = false
                if !self.karaoke { AIVocals.shared.set(false) }
            }
        }
    }

    private var lastSeen: (key: String, playing: Bool, pos: Double, at: Date)?
    /// Tách bằng AI làm nhạc trễ ~4,5 s: dừng, tua hay đổi bài thì bỏ phần nhạc cũ còn trong đệm ngay.
    private func flushIfJumped(_ track: Track?) {
        defer {
            lastSeen = track.map { (Self.key($0), $0.isPlaying, $0.position(at: Date()), Date()) }
        }
        guard SoundCenter.shared.aiVocals, !leavingAI, let last = lastSeen else { return }
        guard let track else { SoundCenter.shared.flushAIVocals(); return }
        let now = Date()
        let expected = last.pos + (last.playing ? now.timeIntervalSince(last.at) : 0)
        if Self.key(track) != last.key || (last.playing && !track.isPlaying)
            || abs(track.position(at: now) - expected) > 1.5 {
            SoundCenter.shared.flushAIVocals()
        }
    }

    /// Dòng đang hát có phải câu khó (để bật giọng dẫn)?
    func isHard(_ index: Int?) -> Bool {
        guard let index, lines.indices.contains(index), let start = lines[index].time else { return false }
        let next = lines[(index + 1)...].first { $0.time != nil }?.time
        return KaraokeGuide.isHard(lines[index].text, start: start, next: next)
    }

    private var sentVocal: Double = 1
    /// Gửi mức giọng thật xuống âm thanh: mức của thanh trượt, hoặc giọng dẫn nếu đang ở câu khó.
    private func pushVocal(force: Bool = false) {
        var level = vocalLevel
        if level < 1, guideHard, isHard(current) { level = max(level, KaraokeGuide.level) }
        if AIVocals.shared.state != .on { level = 1 }   // chưa có AI thì không đụng âm thanh
        guard force || level != sentVocal else { return }
        sentVocal = level
        SoundCenter.shared.setVocalCut(Float(1 - level), app: track?.bundleID)
    }

    /// Chỉ Spotify và Apple Music: tên bài/ca sĩ chuẩn, khớp được với LRCLIB.
    nonisolated static let supportedApps: Set<String> = ["com.spotify.client", "com.apple.Music"]
    nonisolated static func supports(_ track: Track?) -> Bool {
        guard let track, track.duration > 0 else { return false }
        return supportedApps.contains(track.bundleID)
    }

    func seek(to line: LyricLine) {
        guard let t = line.time else { return }
        media?.seek(max(t - 0.05, 0))
    }

    // MARK: - Nạp lời

    private func refresh() {
        guard consumers > 0, let track = self.track else {
            lineTimer?.invalidate(); lineTimer = nil
            return
        }
        let key = Self.key(track)
        if key != loadedKey {
            loadedKey = key
            lines = []; current = nil
            fetchTask?.cancel()
            guard Self.supports(track), enabled || track.bundleID == "com.apple.Music" else { status = .missing; return }
            status = .loading
            fetchTask = Task { [weak self] in
                let result = await LyricsSource.load(track, allowNetwork: self?.enabled ?? false)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.loadedKey == key else { return }
                    self.apply(result)
                }
            }
        }
        sync()
    }

    private func apply(_ result: LyricsSource.Result) {
        switch result {
        case .synced(let l): lines = l; status = .synced
        case .plain(let l): lines = l; status = .plain
        case .none: lines = []; status = .missing
        }
        current = nil
        sync()
    }

    // MARK: - Đồng bộ: hẹn giờ một lần tới dòng kế tiếp (không chạy mỗi khung hình)

    private func sync() {
        lineTimer?.invalidate(); lineTimer = nil
        guard status == .synced, let track = self.track else { return }
        let delay = SoundCenter.shared.heardDelay
        if abs(delay - audioDelay) > 0.005 { audioDelay = delay }
        let pos = heardPosition(track, at: Date())
        let idx = lines.lastIndex { ($0.time ?? .infinity) <= pos + 0.15 }
        if idx != current { current = idx }
        guard track.isPlaying, consumers > 0 else { return }
        let next = (idx.map { $0 + 1 } ?? 0)
        guard next < lines.count, let t = lines[next].time else { return }
        let wait = max(t - pos - 0.1, 0.05)
        lineTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        lineTimer?.tolerance = 0.03
    }

    nonisolated static func key(_ t: Track) -> String {
        "\(t.artist)|\(t.title)|\(t.album)|\(Int(t.duration.rounded()))"
    }
}

/// LRCLIB + lời nhúng của app Music, kèm bộ đệm trên đĩa.
enum LyricsSource {
    enum Result { case synced([LyricLine]), plain([LyricLine]), none }

    private struct Cached: Codable {
        var synced: String?
        var plain: String?
        var missingAt: Date?
    }

    private static let userAgent = "Roost/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (https://github.com/letoan1/notch-app)"
    /// Không tìm thấy thì 3 ngày sau mới hỏi lại.
    private static let missingTTL: TimeInterval = 3 * 86_400

    static func load(_ track: Track, allowNetwork: Bool) async -> Result {
        let file = cacheURL(LyricsStore.key(track))
        if let data = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Cached.self, from: data) {
            if let r = result(c) { return r }
            if let at = c.missingAt, Date().timeIntervalSince(at) < missingTTL {
                return await musicApp(track) ?? .none
            }
        }
        var found: Cached?
        if allowNetwork {
            for q in queries(track) {
                if Task.isCancelled { return .none }
                if let c = await lrclib(title: q.title, artist: q.artist, album: track.album, duration: track.duration) {
                    found = c; break
                }
            }
        }
        let cached = found ?? Cached(missingAt: Date())
        if allowNetwork, let data = try? JSONEncoder().encode(cached) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file)
        }
        if let r = result(cached) { return r }
        return await musicApp(track) ?? .none
    }

    private static func result(_ c: Cached) -> Result? {
        if let s = c.synced, case let lines = parseLRC(s), !lines.isEmpty { return .synced(lines) }
        if let p = c.plain, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .plain(plainLines(p)) }
        return nil
    }

    private static func cacheURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Roost/lyrics/\(hash).json")
    }

    /// Tên bài từ Spotify / Music đã chuẩn: chỉ bỏ phần "feat." để khớp LRCLIB tốt hơn.
    static func queries(_ t: Track) -> [(title: String, artist: String)] {
        var out = [(t.title, t.artist)]
        let title = stripFeat(t.title), artist = stripFeat(t.artist)
        if title != t.title || artist != t.artist { out.append((title, artist)) }
        return out
    }

    private static func stripFeat(_ s: String) -> String {
        var t = s
        for (open, close) in [("(", ")"), ("[", "]")] {
            if let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                let inner = t[a.upperBound..<b.lowerBound].lowercased()
                if inner.hasPrefix("feat") || inner.hasPrefix("ft") || inner.hasPrefix("with ") { t.removeSubrange(a.lowerBound..<b.upperBound) }
            }
        }
        for marker in [" feat. ", " ft. ", " Feat. ", " Ft. "] {
            if let r = t.range(of: marker) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: LRCLIB

    private struct Item: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static func lrclib(title: String, artist: String, album: String, duration: Double) async -> Cached? {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                          .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration.rounded())))]
        if let item: Item = await fetch(get.url!), let c = cached(item) { return c }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        guard let items: [Item] = await fetch(search.url!) else { return nil }
        // Ưu tiên bản có lời đồng bộ và độ dài khớp (±4 s).
        let close = items.filter { abs(($0.duration ?? 0) - duration) <= 4 }
        let pick = close.first { $0.syncedLyrics?.isEmpty == false }
            ?? close.first { $0.plainLyrics?.isEmpty == false }
            ?? items.first { $0.syncedLyrics?.isEmpty == false && abs(($0.duration ?? 0) - duration) <= 10 }
        return pick.flatMap(cached)
    }

    private static func cached(_ i: Item) -> Cached? {
        let s = i.syncedLyrics.flatMap { $0.isEmpty ? nil : $0 }
        let p = i.plainLyrics.flatMap { $0.isEmpty ? nil : $0 }
        guard s != nil || p != nil else { return nil }
        return Cached(synced: s, plain: p)
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Lời nhúng trong app Music

    private static func musicApp(_ t: Track) async -> Result? {
        guard t.bundleID == "com.apple.Music" else { return nil }
        return await Task.detached(priority: .utility) { () -> Result? in
            var err: NSDictionary?
            let script = NSAppleScript(source: "tell application \"Music\" to get lyrics of current track")
            guard let text = script?.executeAndReturnError(&err).stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .plain(plainLines(text))
        }.value
    }

    // MARK: LRC

    static func parseLRC(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var raw: [(Double, String)] = []
        for line in text.components(separatedBy: .newlines) {
            var rest = Substring(line)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if tag.lowercased().hasPrefix("offset:") {
                    offset = (Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                } else if let t = parseTime(tag) {
                    times.append(t)
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for t in times { raw.append((t, words)) }
        }
        let sorted = raw.sorted { $0.0 < $1.0 }
        return sorted.enumerated().map { i, item in
            LyricLine(id: i, time: max(item.0 - offset, 0), text: item.1.isEmpty ? "♪" : item.1)
        }
    }

    private static func parseTime(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    }

    static func plainLines(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }
}
