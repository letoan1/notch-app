import AppKit
import Combine
import SwiftUI

enum Player: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    /// Player tự phát distributed notification khi đổi bài / play / pause.
    var notificationName: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        }
    }

    /// Spotify trả duration theo ms, Music theo giây.
    var infoScript: String {
        let duration = self == .spotify ? "(duration of t) / 1000" : "duration of t"
        let art = self == .spotify ? "artwork url of t" : "\"\""
        return """
        tell application "\(rawValue)"
            set t to current track
            return {player state as string, name of t, artist of t, album of t, \(art), \(duration), player position}
        end tell
        """
    }
}

struct Track: Equatable {
    /// App đang phát (trình duyệt, Podcasts, Spotify…): mở app, nghe sóng nhạc.
    var bundleID: String
    var appName: String
    /// Spotify / Music: điều khiển được bằng AppleScript khi không có MediaRemote.
    var player: Player?
    var title: String
    var artist: String
    var album: String
    var artworkURL: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var fetchedAt: Date

    /// Nội suy vị trí giữa 2 lần đọc để thanh progress chạy liên tục.
    func position(at date: Date) -> Double {
        let p = isPlaying ? position + date.timeIntervalSince(fetchedAt) : position
        return min(max(p, 0), duration)
    }

    /// Bỏ qua lệch vị trí nhỏ để không re-render vô ích mỗi lần đọc.
    func sameMoment(as other: Track) -> Bool {
        let now = Date()
        return bundleID == other.bundleID && title == other.title && artist == other.artist
            && album == other.album && isPlaying == other.isPlaying && duration == other.duration
            && abs(position(at: now) - other.position(at: now)) < 1.5
    }
}

enum RepeatMode: Equatable { case off, all, one }

/// Chế độ trộn / lặp của bài đang phát. nil = nguồn không cho điều khiển (trình duyệt, Podcasts…).
struct PlayModes: Equatable {
    var shuffle: Bool
    var repeatMode: RepeatMode
    /// Spotify chỉ có lặp bật / tắt qua AppleScript, không có lặp một bài.
    var supportsRepeatOne: Bool
    /// Đọc / đặt qua MediaRemote (Music báo lên được); không thì qua AppleScript.
    var viaAdapter: Bool
}

/// Apple event là IPC đồng bộ (~0.2s, lần đầu ~2s): chạy trên main sẽ làm khựng animation,
/// nên mọi script đi qua một serial queue riêng.
final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "notch.applescript", qos: .userInitiated)
    private var cache: [String: NSAppleScript] = [:]

    func async(_ work: @escaping (ScriptRunner) -> Void) {
        queue.async { work(self) }
    }

    func run(_ source: String) -> NSAppleEventDescriptor? {
        dispatchPrecondition(condition: .onQueue(queue))
        let script = cache[source] ?? {
            let s = NSAppleScript(source: source)!
            cache[source] = s
            return s
        }()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    func fetchModes(_ player: Player) -> PlayModes? {
        let src = player == .spotify
            ? "tell application \"Spotify\" to return {shuffling, repeating}"
            : "tell application \"Music\" to return {shuffle enabled, song repeat as string}"
        guard let d = run(src), d.numberOfItems == 2 else { return nil }
        let rep: RepeatMode
        if player == .spotify {
            rep = d.atIndex(2)?.booleanValue == true ? .all : .off
        } else {
            switch d.atIndex(2)?.stringValue { case "one": rep = .one; case "all": rep = .all; default: rep = .off }
        }
        return PlayModes(shuffle: d.atIndex(1)?.booleanValue ?? false, repeatMode: rep,
                         supportsRepeatOne: player == .music, viaAdapter: false)
    }

    func fetch(_ player: Player) -> Track? {
        guard let d = run(player.infoScript), d.numberOfItems == 7,
              let state = d.atIndex(1)?.stringValue,
              let title = d.atIndex(2)?.stringValue, !title.isEmpty
        else { return nil }
        return Track(
            bundleID: player.bundleID,
            appName: player.rawValue,
            player: player,
            title: title,
            artist: d.atIndex(3)?.stringValue ?? "",
            album: d.atIndex(4)?.stringValue ?? "",
            artworkURL: d.atIndex(5)?.stringValue ?? "",
            duration: d.atIndex(6)?.doubleValue ?? 0,
            position: d.atIndex(7)?.doubleValue ?? 0,
            isPlaying: state == "playing",
            fetchedAt: Date()
        )
    }
}

/// Bài đang phát. Nguồn chính: MediaRemote qua mediaremote-adapter (mọi app, đẩy theo sự kiện).
/// Adapter hỏng / không có gì → tự quay về AppleScript cho Spotify / Music như trước.
@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track? {
        didSet {
            syncSpectrum()
            ArcadeStats.shared.trackChanged(from: oldValue, to: track)
        }
    }
    @Published private(set) var artwork: NSImage? {
        didSet {
            artworkAccent = artwork.flatMap { $0.accentColor() }.map(Color.init(nsColor:)) ?? .white
            applyAccent()
        }
    }
    /// Màu nhấn (thanh progress, sóng nhạc, quầng sáng): theo ảnh bìa, hoặc màu cố định trong Cài đặt.
    @Published private(set) var accent: Color = SettingsStore.shared.fixedAccent ?? .white
    private var artworkAccent: Color = .white
    private var accentSink: AnyCancellable?

    init() {
        accentSink = SettingsStore.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange chạy trước khi giá trị đổi: đọc lại ở nhịp sau.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyAccent() } }
        }
    }

    private func applyAccent() {
        let next = SettingsStore.shared.fixedAccent ?? artworkAccent
        if next != accent { accent = next }
    }

    var isPlaying: Bool { track?.isPlaying == true }
    /// Có bài (đang phát hoặc tạm dừng): giữ 2 cánh notch.
    var hasTrack: Bool { track != nil }

    private let runner = ScriptRunner()
    private var timer: Timer?
    private var refreshing = false
    private var pending = false
    private var artworkKey = ""
    /// Sau khi bấm play/pause: trạng thái chờ player xác nhận. Kết quả đọc trái ngược trong
    /// khoảng này là dữ liệu cũ (lần đọc chạy dở, player chưa kịp đổi) → bỏ qua để icon không nhảy.
    private var expected: (playing: Bool, until: Date)?
    /// Sau khi tua: bỏ qua kết quả đọc còn vị trí cũ (lệch > 2s so với đích) trong 1.5s.
    private var seekTarget: (position: Double, at: Date)?

    // MediaRemote
    private let adapter = MediaRemoteAdapter()
    /// Adapter đang chạy và đã in ít nhất 1 dòng.
    private var adapterLive = false
    private var adapterTrack: Track?
    private var latestAdapter: Track?
    private var reapplyScheduled = false
    private var adapterFailures = 0
    private var appNames: [String: String] = [:]

    private var usingAdapter: Bool { adapterLive && adapterTrack != nil }

    func start() {
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            center.addObserver(forName: player.notificationName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        if let adapter {
            adapter.onUpdate = { [weak self] snap in
                Task { @MainActor in self?.receive(snap) }
            }
            adapter.onExit = { [weak self] lived in
                Task { @MainActor in self?.adapterExited(after: lived) }
            }
            adapter.start()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { [weak adapter] _ in
                adapter?.stop()
            }
        }
        updateTimer()
        // Có adapter: đợi dòng đầu tiên của nó (tới ngay) rồi mới tính chuyện AppleScript,
        // để lúc mở app không gửi Apple event (và không bật hộp thoại quyền) khi MediaRemote đã có bài.
        if adapter == nil { refresh() }
    }

    func playPause() {
        // Đổi icon ngay, không đợi player trả lời.
        if var t = track {
            t.position = t.position(at: Date())
            t.fetchedAt = Date()
            t.isPlaying.toggle()
            setTrack(t)
            expected = (t.isPlaying, Date().addingTimeInterval(2))
        }
        if usingAdapter { adapter?.playPause() } else { send("playpause") }
    }

    func next() {
        if usingAdapter { adapter?.next() } else { send("next track") }
    }

    func previous() {
        if usingAdapter { adapter?.previous() } else { send("previous track") }
    }

    /// Chỉ nghe âm thanh khi đang phát + bật trong Cài đặt.
    func syncSpectrum() {
        let bundle = track?.isPlaying == true && AudioSpectrum.enabled ? track?.bundleID : nil
        AudioSpectrum.shared.follow(bundle)
    }

    /// Tua tới `seconds`.
    func seek(_ seconds: Double) {
        guard var t = track else { return }
        pauseHold = nil  // tua lùi lúc đang dừng là cố ý
        t.position = seconds
        t.fetchedAt = Date()
        setTrack(t)
        seekTarget = (seconds, Date())
        if usingAdapter {
            adapter?.seek(seconds)
        } else {
            send("set player position to \(String(format: "%.2f", seconds))")
        }
    }

    /// Đưa app đang phát lên trước (trình duyệt, Spotify, Podcasts…).
    func openPlayer() {
        guard let bundle = track?.bundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Trộn / lặp

    @Published private(set) var modes: PlayModes?
    private var adapterModes: (bundle: String, shuffle: Int?, rep: Int?)?
    private var modesKey = ""
    /// Spotify báo sai trộn / lặp qua AppleScript (luôn "tắt"), nên nhớ lần bấm cuối trên Roost và dùng giá trị đó.
    private var spotifyModes: PlayModes?

    /// Đọc lại chế độ trộn / lặp: khi đổi bài, đổi trạng thái phát, sau khi bấm, hoặc khi mở notch.
    func refreshModes(force: Bool = false) {
        guard let track else {
            modesKey = ""
            if modes != nil { modes = nil }
            return
        }
        let key = "\(track.bundleID)|\(track.title)|\(track.isPlaying)"
        guard force || key != modesKey else { return }
        modesKey = key
        // MediaRemote có báo (Music…): dùng luôn, đặt lại cũng qua MediaRemote.
        if let m = adapterModes, m.bundle == track.bundleID, let sh = m.shuffle, let rp = m.rep, sh > 0, rp > 0 {
            let next = PlayModes(shuffle: sh > 1, repeatMode: rp == 2 ? .one : rp == 3 ? .all : .off,
                                 supportsRepeatOne: true, viaAdapter: true)
            if modes != next { modes = next }
            return
        }
        // Spotify / Music đang chạy: hỏi bằng AppleScript. Nguồn khác: ẩn nút.
        guard let player = track.player,
              !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
        else {
            if modes != nil { modes = nil }
            return
        }
        if player == .spotify, let m = spotifyModes {
            if modes != m { modes = m }
            return
        }
        // Chỉ hỏi khi trình phát đang hiện (force), không hỏi mỗi lần đổi bài lúc notch đóng.
        guard force else { modesKey = ""; return }
        let bundle = track.bundleID
        runner.async { [weak self] r in
            let m = r.fetchModes(player)
            Task { @MainActor in
                guard let self, self.track?.bundleID == bundle, self.modes != m else { return }
                self.modes = m
            }
        }
    }

    func toggleShuffle() {
        guard var m = modes else { return }
        m.shuffle.toggle()
        modes = m
        if m.viaAdapter {
            adapter?.setShuffle(m.shuffle ? 3 : 1)
            confirmModes()
            return
        }
        guard let player = track?.player else { return }
        sendMode(player == .spotify ? "set shuffling to \(m.shuffle)" : "set shuffle enabled to \(m.shuffle)",
                 player, want: m, shuffle: true)
    }

    /// Tắt → lặp danh sách → lặp một bài (nếu có) → tắt.
    func cycleRepeat() {
        guard var m = modes else { return }
        switch m.repeatMode {
        case .off: m.repeatMode = .all
        case .all: m.repeatMode = m.supportsRepeatOne ? .one : .off
        case .one: m.repeatMode = .off
        }
        modes = m
        if m.viaAdapter {
            adapter?.setRepeat(m.repeatMode == .one ? 2 : m.repeatMode == .all ? 3 : 1)
            confirmModes()
            return
        }
        guard let player = track?.player else { return }
        let command = player == .spotify
            ? "set repeating to \(m.repeatMode != .off)"
            : "set song repeat to \(m.repeatMode == .one ? "one" : m.repeatMode == .all ? "all" : "off")"
        sendMode(command, player, want: m, shuffle: false)
    }

    private func sendMode(_ command: String, _ player: Player, want: PlayModes, shuffle: Bool) {
        // Spotify: đọc lại thì luôn ra "tắt" → trước đây Roost tưởng lệnh không ăn và bấm bù qua MediaRemote,
        // làm lật ngược lựa chọn. Gửi lệnh rồi tin lựa chọn của người dùng.
        if player == .spotify {
            spotifyModes = want
            runner.async { r in _ = r.run("tell application \"\(player.rawValue)\" to \(command)") }
            return
        }
        runner.async { [weak self] r in
            _ = r.run("tell application \"\(player.rawValue)\" to \(command)")
            Thread.sleep(forTimeInterval: 0.4)
            let got = r.fetchModes(player)
            let applied = shuffle ? got?.shuffle == want.shuffle : got?.repeatMode == want.repeatMode
            Task { @MainActor in
                guard let self else { return }
                // Vài bản Spotify nhận lệnh AppleScript mà không đổi gì: thử lệnh MediaRemote của app đang phát.
                if !applied, self.adapterTrack?.bundleID == player.bundleID {
                    if shuffle { self.adapter?.toggleShuffle() } else { self.adapter?.toggleRepeat() }
                }
                self.confirmModes()
            }
        }
    }

    /// Đọc lại sau khi bấm (player có thể từ chối, vd. tài khoản Spotify miễn phí).
    private func confirmModes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.refreshModes(force: true) }
        }
    }

    // MARK: - AppleScript (dự phòng)

    func refresh() {
        guard !usingAdapter else { return }
        if refreshing { pending = true; return }
        refreshing = true
        // Chỉ gửi Apple event khi app đang chạy: `tell application` sẽ tự mở app nếu nó tắt.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let players = Player.allCases.filter { running.contains($0.bundleID) }
        runner.async { [weak self] r in
            let tracks = players.compactMap(r.fetch)
            let next = tracks.first(where: \.isPlaying) ?? tracks.first
            Task { @MainActor in self?.apply(next) }
        }
    }

    private func apply(_ next: Track?) {
        refreshing = false
        // MediaRemote đã có bài: kết quả AppleScript chạy dở thì bỏ.
        guard !usingAdapter else { pending = false; return }
        if let e = expected {
            if Date() < e.until, let n = next, n.isPlaying != e.playing {
                if pending {
                    pending = false
                    refresh()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        MainActor.assumeIsolated { self?.refresh() }
                    }
                }
                return
            }
            expected = nil
        }
        if let s = seekTarget, let n = next {
            let elapsed = Date().timeIntervalSince(s.at)
            let want = s.position + (n.isPlaying ? elapsed : 0)
            if elapsed < 1.5, n.title == track?.title, abs(n.position(at: Date()) - want) > 2 {
                if pending { pending = false; refresh() }
                return
            }
            seekTarget = nil
        }
        setTrack(next)
        updateArtwork(for: next)
        if pending { pending = false; refresh() }
    }

    private func send(_ command: String) {
        guard let player = track?.player else { return }
        runner.async { [weak self] r in
            _ = r.run("tell application \"\(player.rawValue)\" to \(command)")
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Notification không bắn khi tua bài → poll chậm, chỉ khi không có MediaRemote (adapter hỏng / không có).
    /// Adapter sống mà chưa có bài: Spotify / Music vẫn báo qua distributed notification, không cần poll.
    private func updateTimer() {
        if adapterLive {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            t.tolerance = 0.5
            timer = t
        }
    }

    /// Vị trí lúc vừa dừng. Spotify / MediaRemote hay báo vị trí dừng cũ hơn vài giây, làm thanh giật lùi.
    private var pauseHold: (title: String, position: Double, until: Date)?

    private func setTrack(_ next: Track?) {
        var next = next
        let now = Date()
        if let cur = track, cur.isPlaying, let n = next, !n.isPlaying, n.title == cur.title {
            pauseHold = (cur.title, cur.position(at: now), now.addingTimeInterval(4))
        }
        if let h = pauseHold, var n = next {
            if n.isPlaying || n.title != h.title || now > h.until {
                pauseHold = nil
            } else if n.position < h.position, h.position - n.position < 6 {
                n.position = h.position
                n.fetchedAt = now
                next = n
            }
        }
        let unchanged: Bool
        switch (track, next) {
        case (nil, nil): unchanged = true
        case let (a?, b?): unchanged = a.sameMoment(as: b)
        default: unchanged = false
        }
        if !unchanged { track = next }
        refreshModes()
    }

    private func updateArtwork(for track: Track?) {
        guard let track else { artworkKey = ""; artwork = nil; return }
        let key = "\(track.bundleID)|\(track.title)|\(track.album)"
        guard key != artworkKey, let player = track.player else { return }
        artworkKey = key

        switch player {
        case .spotify:
            guard let url = URL(string: track.artworkURL) else { artwork = nil; return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      self.artworkKey == key else { return }
                self.artwork = NSImage(data: data)
            }
        case .music:
            runner.async { [weak self] r in
                let data = r.run("tell application \"Music\" to get data of artwork 1 of current track")?.data
                Task { @MainActor in
                    guard let self, self.artworkKey == key else { return }
                    self.artwork = data.flatMap(NSImage.init(data:))
                }
            }
        }
    }

    // MARK: - MediaRemote

    private func receive(_ snap: MediaRemoteAdapter.Snapshot?) {
        let wasLive = adapterLive
        adapterLive = true
        if !wasLive { adapterFailures = 0; updateTimer() }
        guard let snap else {
            latestAdapter = nil
            adapterTrack = nil
            updateTimer()
            // Không có gì trên MediaRemote: để AppleScript đọc lại (có thể vẫn còn Spotify tạm dừng).
            setTrack(nil)
            artworkKey = ""
            artwork = nil
            refresh()
            return
        }
        let bundle = snap.parentBundleID ?? snap.bundleID
        let newModes = (bundle: bundle, shuffle: snap.shuffleMode, rep: snap.repeatMode)
        let modesChanged = adapterModes.map { $0.bundle != bundle || $0.shuffle != snap.shuffleMode || $0.rep != snap.repeatMode } ?? true
        adapterModes = newModes
        let next = Track(
            bundleID: bundle,
            appName: appName(for: bundle),
            player: Player.allCases.first { $0.bundleID == bundle },
            title: snap.title,
            artist: snap.artist,
            album: snap.album,
            artworkURL: "",
            duration: snap.duration,
            position: snap.elapsed,
            isPlaying: snap.playing,
            fetchedAt: snap.timestamp ?? Date()
        )
        if snap.artworkChanged || !snap.hasArtwork {
            artworkKey = "mr"
            artwork = snap.artwork.flatMap(NSImage.init(data:))
        }
        latestAdapter = next
        applyAdapter()
        if modesChanged { refreshModes(force: true) }
    }

    /// Áp bài mới nhất từ MediaRemote, trừ khi nó còn mang trạng thái cũ ngay sau khi bấm / tua.
    private func applyAdapter() {
        guard let next = latestAdapter else { return }
        let now = Date()
        if let e = expected, now < e.until, next.isPlaying != e.playing {
            reapply(at: e.until)
            return
        }
        expected = nil
        if let s = seekTarget {
            let elapsed = now.timeIntervalSince(s.at)
            let want = s.position + (next.isPlaying ? elapsed : 0)
            if elapsed < 1.5, next.title == track?.title, abs(next.position(at: now) - want) > 2 {
                reapply(at: s.at.addingTimeInterval(1.5))
                return
            }
            seekTarget = nil
        }
        adapterTrack = next
        updateTimer()
        setTrack(next)
    }

    private func reapply(at date: Date) {
        guard !reapplyScheduled else { return }
        reapplyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(date.timeIntervalSinceNow, 0.05)) { [weak self] in
            MainActor.assumeIsolated {
                self?.reapplyScheduled = false
                self?.applyAdapter()
            }
        }
    }

    /// Stream chết: thử lại (giãn dần); chết nhanh 3 lần liên tiếp thì bỏ, dùng hẳn AppleScript.
    private func adapterExited(after lived: TimeInterval) {
        adapterLive = false
        adapterTrack = nil
        latestAdapter = nil
        if artworkKey == "mr" { artworkKey = "" }
        updateTimer()
        refresh()
        adapterFailures = lived < 10 ? adapterFailures + 1 : 1
        guard adapterFailures < 3 else { return }
        let delay = Double(adapterFailures) * 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.adapter?.start() }
        }
    }

    private func appName(for bundle: String) -> String {
        if let cached = appNames[bundle] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundle
        appNames[bundle] = name
        return name
    }
}
