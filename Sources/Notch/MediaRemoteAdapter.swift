import Foundation

/// Cầu nối tới mediaremote-adapter (BSD-3, đóng gói trong app): `/usr/bin/perl` được phép dùng
/// MediaRemote nên đọc được "đang phát" của mọi app (trình duyệt, podcast…), kể cả macOS 15.4+.
/// Một tiến trình `stream` sống suốt (chỉ in khi có thay đổi), lệnh điều khiển chạy tiến trình ngắn riêng.
final class MediaRemoteAdapter: @unchecked Sendable {
    struct Snapshot: Sendable {
        var bundleID: String
        var parentBundleID: String?
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var timestamp: Date?
        var playing: Bool
        var hasArtwork: Bool
        /// Chỉ có khi ảnh bìa vừa đổi (base64 đã giải mã).
        var artwork: Data?
        var artworkChanged: Bool
        /// Chế độ trộn / lặp nếu app có báo lên MediaRemote (Music có, Spotify thường không). 1 = tắt.
        var shuffleMode: Int?
        var repeatMode: Int?
    }

    private let script: String
    private let framework: String
    private let queue = DispatchQueue(label: "notch.mediaremote", qos: .userInitiated)

    // Chỉ dùng trên `queue`.
    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var lastArtwork: String?
    private var gotData = false
    private var generation = 0

    /// nil = không có gì đang phát.
    var onUpdate: (@Sendable (Snapshot?) -> Void)?
    /// Tiến trình stream chết ngoài ý muốn (thời gian đã sống, giây).
    var onExit: (@Sendable (TimeInterval) -> Void)?

    init?(bundle: Bundle = .main) {
        guard let script = bundle.path(forResource: "mediaremote-adapter", ofType: "pl"),
              let frameworks = bundle.privateFrameworksPath
        else { return nil }
        let framework = frameworks + "/MediaRemoteAdapter.framework"
        guard FileManager.default.fileExists(atPath: framework + "/MediaRemoteAdapter"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")
        else { return nil }
        self.script = script
        self.framework = framework
    }

    func start() {
        queue.async { [self] in
            guard process == nil else { return }
            killOrphans()
            launch()
        }
    }

    func stop() {
        queue.sync { [self] in
            generation += 1
            process?.terminate()
            process = nil
        }
    }

    func playPause() { run(["send", "2"]) }
    func next() { run(["send", "4"]) }
    func previous() { run(["send", "5"]) }
    func seek(_ seconds: Double) { run(["seek", String(Int64(max(seconds, 0) * 1_000_000))]) }
    /// Bật / tắt trộn (6) và đổi kiểu lặp (7) theo thứ tự của chính app đang phát.
    func toggleShuffle() { run(["send", "6"]) }
    func toggleRepeat() { run(["send", "7"]) }
    /// 1 tắt, 2 trộn album, 3 trộn bài.
    func setShuffle(_ mode: Int) { run(["shuffle", String(mode)]) }
    /// 1 tắt, 2 lặp một bài, 3 lặp danh sách.
    func setRepeat(_ mode: Int) { run(["repeat", String(mode)]) }

    // MARK: - Tiến trình

    private func launch() {
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--micros", "--debounce=60"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        buffer.removeAll()
        state.removeAll()
        lastArtwork = nil
        gotData = false
        let started = Date()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { if !data.isEmpty { self?.consume(data, gen: gen) } }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self, self.generation == gen else { return }
                self.process = nil
                self.onExit?(Date().timeIntervalSince(started))
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            onExit?(0)
            return
        }
        // Dòng đầu tiên luôn tới ngay (payload rỗng nếu không có gì phát); im lặng = adapter hỏng.
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == gen, !self.gotData else { return }
            self.process?.terminate()
        }
    }

    /// Bản cũ còn sót (app bị kill -9) sẽ tự chết khi in tiếp, nhưng dọn luôn cho sạch.
    private func killOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", script + " " + framework + " stream"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func run(_ args: [String]) {
        queue.async { [script, framework] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [script, framework] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    // MARK: - Đọc JSON từng dòng

    private func consume(_ data: Data, gen: Int) {
        guard gen == generation else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            gotData = true
            if obj["diff"] as? Bool == true {
                for (k, v) in payload {
                    if v is NSNull { state.removeValue(forKey: k) } else { state[k] = v }
                }
            } else {
                state = payload
            }
            onUpdate?(snapshot())
        }
    }

    private func snapshot() -> Snapshot? {
        guard let bundle = state["bundleIdentifier"] as? String,
              let title = state["title"] as? String, !title.isEmpty
        else { lastArtwork = nil; return nil }
        func num(_ k: String) -> Double? { (state[k] as? NSNumber)?.doubleValue }
        let art = state["artworkData"] as? String
        let changed = art != lastArtwork
        lastArtwork = art
        return Snapshot(
            bundleID: bundle,
            parentBundleID: state["parentApplicationBundleIdentifier"] as? String,
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            duration: (num("durationMicros") ?? 0) / 1_000_000,
            elapsed: (num("elapsedTimeMicros") ?? 0) / 1_000_000,
            timestamp: num("timestampEpochMicros").map { Date(timeIntervalSince1970: $0 / 1_000_000) },
            playing: state["playing"] as? Bool ?? false,
            hasArtwork: art != nil,
            artwork: changed ? art.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } : nil,
            artworkChanged: changed,
            shuffleMode: (state["shuffleMode"] as? NSNumber)?.intValue,
            repeatMode: (state["repeatMode"] as? NSNumber)?.intValue
        )
    }
}
