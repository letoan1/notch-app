import AppKit
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
    var player: Player
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
        return player == other.player && title == other.title && artist == other.artist
            && album == other.album && isPlaying == other.isPlaying && duration == other.duration
            && abs(position(at: now) - other.position(at: now)) < 1.5
    }
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

    func fetch(_ player: Player) -> Track? {
        guard let d = run(player.infoScript), d.numberOfItems == 7,
              let state = d.atIndex(1)?.stringValue,
              let title = d.atIndex(2)?.stringValue, !title.isEmpty
        else { return nil }
        return Track(
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

@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage? {
        didSet { accent = artwork.flatMap { $0.accentColor() }.map(Color.init(nsColor:)) ?? .white }
    }
    /// Màu nhấn lấy từ ảnh bìa (thanh progress, sóng nhạc).
    @Published private(set) var accent: Color = .white

    var isPlaying: Bool { track?.isPlaying == true }
    /// Có bài (đang phát hoặc tạm dừng): giữ 2 cánh notch.
    var hasTrack: Bool { track != nil }

    private let runner = ScriptRunner()
    private var timer: Timer?
    private var refreshing = false
    private var pending = false
    private var artworkKey = ""

    func start() {
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            center.addObserver(forName: player.notificationName, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // Notification không bắn khi tua bài, poll chậm để đồng bộ lại vị trí.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func playPause() {
        // Đổi icon ngay, không đợi player trả lời.
        if var t = track {
            t.position = t.position(at: Date())
            t.fetchedAt = Date()
            t.isPlaying.toggle()
            track = t
        }
        send("playpause")
    }

    func next() { send("next track") }

    /// Đưa app đang phát (Spotify / Music) lên trước.
    func openPlayer() {
        guard let player = track?.player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func previous() { send("previous track") }

    func refresh() {
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
        let unchanged: Bool
        switch (track, next) {
        case (nil, nil): unchanged = true
        case let (a?, b?): unchanged = a.sameMoment(as: b)
        default: unchanged = false
        }
        if !unchanged { track = next }
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

    private func updateArtwork(for track: Track?) {
        guard let track else { artworkKey = ""; artwork = nil; return }
        let key = "\(track.player.rawValue)|\(track.title)|\(track.album)"
        guard key != artworkKey else { return }
        artworkKey = key

        switch track.player {
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
}
