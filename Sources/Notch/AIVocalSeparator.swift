import Accelerate
import CoreML
import CryptoKit
import Foundation
import SwiftUI

/// Tách giọng bằng AI: model UVR MDX-Net Voc_FT (MDXVocals, Core ML fp16, 33 MB, ~200 MB RAM, ở Application Support/Roost/Models).
/// Model cần 5,92 s âm thanh mỗi lần, M2 chạy ~0,15–0,2 s, nên nhạc trễ cố định `delaySeconds` (~1,2 s):
/// mỗi 0,4 s chạy model trên 5,92 s mới nhất, lấy giọng của đoạn cách mép cuối 0,35 s (mép cửa sổ kém chính xác).
/// Đo trên bài thật (KaraokeSelfTest): trễ 1,2 s tách giọng tốt ngang 2,5 s; 1,0 s thì model không kịp.
/// Luồng IO chỉ chép vào / đọc ra vòng đệm: ra = nhạc gốc (trễ) − mức × giọng, nên thanh trượt và giọng dẫn
/// vẫn đổi ngay. Chưa có giọng cho đoạn nào (máy chậm, vừa bật) thì đoạn đó phát nguyên bản.
final class AIVocalSeparator: @unchecked Sendable {
    static let modelURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Roost/Models/UVR-MDX-NET-Voc_FT.mlmodelc")
    static let modelFFT = 6144
    static var installed: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    /// Model dùng chung mọi tap; nạp / gỡ ở AIVocals.
    nonisolated(unsafe) static var model: MDXVocals?

    static let modelRate = 44100.0
    static let modelFrames = MDXVocals.frames       // 5,92 s
    static let hopSeconds = 0.4, marginSeconds = 0.35
    static let delaySeconds = hopSeconds + marginSeconds + 0.45   // + thời gian chạy model và nhịp kiểm 0,05 s   // + chỗ cho thời gian chạy model khi máy bận

    let rate: Double
    let delay: Int
    /// Mức bỏ giọng 0…1 (dùng chung với thanh trượt).
    let level = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// 1 = đang bật (luồng điều khiển ghi, luồng IO đọc).
    let enabled = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    private let cap: Int, hop: Int, margin: Int, fade: Int, window: Int
    private let dryL, dryR, vocL, vocR: UnsafeMutablePointer<Float>
    /// [0] số mẫu đã ghi (W), [1] giọng hợp lệ tới mẫu (V), [2] im lặng mọi mẫu trước mốc này (dừng / tua).
    private let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 3)
    private var current: Float = 0                    // chỉ luồng IO
    private var fadeIn: Float = 0                     // chỉ luồng IO: hết đoạn im thì to dần ~0,15 s, không bật cái bụp

    private let queue = DispatchQueue(label: "roost.ai.vocals", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var nextStart: Int64 = -1                 // chỉ trên `queue`
    private var winL = [Float](), winR = [Float](), outL = [Float](), outR = [Float]()

    init(sampleRate: Double) {
        rate = sampleRate
        delay = Int(Self.delaySeconds * sampleRate)
        hop = Int(Self.hopSeconds * sampleRate)
        margin = Int(Self.marginSeconds * sampleRate)
        fade = Int(0.1 * sampleRate)
        window = Int((Double(Self.modelFrames) / Self.modelRate * sampleRate).rounded())
        let cap = window + delay + hop * 2
        self.cap = cap
        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            p.initialize(repeating: 0, count: cap)
            return p
        }
        dryL = buf(); dryR = buf(); vocL = buf(); vocR = buf()
        counters.initialize(repeating: 0, count: 3)
        level.pointee = 0
        enabled.pointee = 0
    }

    deinit {
        timer?.cancel()
        for p in [dryL, dryR, vocL, vocR, level] { p.deallocate() }
        counters.deallocate()
        enabled.deallocate()
    }

    func setEnabled(_ on: Bool) {
        queue.async { [self] in
            guard (enabled.pointee != 0) != on else { return }
            if on {
                nextStart = -1
                counters[2] = counters[0]   // bật lại: đừng phát phần nhạc cũ còn trong đệm
                OSMemoryBarrier()
                enabled.pointee = 1
                NSLog("[RoostAI] bat, rate %.0f, tre %d mau", rate, delay)
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
                t.setEventHandler { [weak self] in self?.work() }
                t.resume()
                timer = t
            } else {
                enabled.pointee = 0
                timer?.cancel(); timer = nil
            }
        }
    }

    /// Dừng / tua / đổi bài: bỏ phần nhạc cũ còn trong đệm thay vì phát tiếp ~4,5 s.
    func flush() {
        OSMemoryBarrier()
        counters[2] = counters[0]
        NSLog("[RoostAI] flush tai W %lld", counters[0])
    }

    // MARK: - Luồng IO thời gian thực

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, stride: Int, frames: Int,
                 oL: UnsafeMutablePointer<Float>, oR: UnsafeMutablePointer<Float>) {
        let w = counters[0]
        for i in 0..<frames {
            let j = Int((w + Int64(i)) % Int64(cap))
            dryL[j] = left[i * stride]
            dryR[j] = right[i * stride]
        }
        OSMemoryBarrier()
        counters[0] = w + Int64(frames)

        let valid = counters[1], silentBefore = counters[2]
        let goal = level.pointee
        let maxStep = 1 / Float(rate * 0.2)   // đổi mức trong ~0,2 s
        let fadeStep = 1 / Float(rate * 0.15)
        for i in 0..<frames {
            current += min(max(goal - current, -maxStep), maxStep)
            let r = w + Int64(i) - Int64(delay)
            if r < 0 || r < silentBefore { oL[i] = 0; oR[i] = 0; fadeIn = 0; continue }
            fadeIn = min(1, fadeIn + fadeStep)
            let j = Int(r % Int64(cap))
            let g: Float = r < valid ? current : 0
            oL[i] = (dryL[j] - g * vocL[j]) * fadeIn
            oR[i] = (dryR[j] - g * vocR[j]) * fadeIn
        }
    }

    // MARK: - Luồng chạy model

    private func work() {
        guard enabled.pointee != 0, let model = Self.model else { return }
        OSMemoryBarrier()
        let w = counters[0]
        if nextStart < 0 { nextStart = max(w - Int64(margin + hop), 0) }
        // Chậm hơn nhạc (máy bận): bỏ qua tới đoạn mới nhất còn kịp phát.
        if nextStart + Int64(hop) < w - Int64(delay) { nextStart = max(w - Int64(margin + hop), 0) }
        let s = nextStart
        let end = s + Int64(hop + margin)
        guard end <= w else { return }

        // Cửa sổ [end − window, end) theo tần số thiết bị.
        let start = end - Int64(window)
        if winL.count != window { winL = [Float](repeating: 0, count: window); winR = winL }
        for i in 0..<window {
            let a = start + Int64(i)
            if a < 0 { winL[i] = 0; winR[i] = 0; continue }
            let j = Int(a % Int64(cap))
            winL[i] = dryL[j]; winR[i] = dryR[j]
        }
        guard let vocals = Self.separate(model, winL, winR) else { NSLog("[RoostAI] model lỗi"); return }
        if outL.count != window { outL = [Float](repeating: 0, count: window); outR = outL }
        Self.resample(vocals.l, into: &outL)
        Self.resample(vocals.r, into: &outR)

        // Ghi giọng của [s − fade, s + hop): phần chồng lên đoạn trước thì trộn dần cho khỏi đường nối.
        let first = s - Int64(fade)
        for a in max(first, 0)..<(s + Int64(hop)) {
            let idx = Int(a - start)
            guard idx >= 0, idx < window else { continue }
            let j = Int(a % Int64(cap))
            if a < s {
                let t = Float(a - first) / Float(fade)
                vocL[j] = vocL[j] * (1 - t) + outL[idx] * t
                vocR[j] = vocR[j] * (1 - t) + outR[idx] * t
            } else {
                vocL[j] = outL[idx]; vocR[j] = outR[idx]
            }
        }
        OSMemoryBarrier()
        counters[1] = s + Int64(hop)
        nextStart = s + Int64(hop)
    }

    /// Giọng của một cửa sổ (đổi về 44,1 kHz cho model, trả lại đúng độ dài vào).
    static func separate(_ model: MDXVocals, _ l: [Float], _ r: [Float]) -> (l: [Float], r: [Float])? {
        var tl = [Float](repeating: 0, count: modelFrames), tr = tl
        resample(l, into: &tl); resample(r, into: &tr)
        guard let v = model.vocals(tl, tr) else { return nil }
        if l.count == modelFrames { return v }
        var ol = [Float](repeating: 0, count: l.count), or = ol
        resample(v.l, into: &ol); resample(v.r, into: &or)
        return (ol, or)
    }

    /// Đổi số mẫu bằng nội suy tuyến tính (cùng độ dài thì chép thẳng).
    /// shortcut: tuyến tính làm mờ phần rất cao; nếu loa chạy khác 44,1 kHz mà nghe còn giọng "xì" thì đổi sang AVAudioConverter.
    static func resample(_ src: [Float], into dst: inout [Float]) {
        if src.count == dst.count { dst = src; return }
        let scale = Double(src.count - 1) / Double(max(dst.count - 1, 1))
        for i in 0..<dst.count {
            let x = Double(i) * scale
            let k = Int(x), f = Float(x - Double(k))
            dst[i] = k + 1 < src.count ? src[k] * (1 - f) + src[k + 1] * f : src[src.count - 1]
        }
    }
}

/// Bật / tắt tách giọng bằng AI: nạp model (~5 s), chạy nháp, rồi mới chuyển âm thanh sang đường AI.
/// Tắt thì gỡ model (giải phóng ~200 MB RAM).
@MainActor
final class AIVocals: ObservableObject {
    static let shared = AIVocals()
    enum State { case off, loading, on, failed }
    @Published private(set) var state: State = .off
    @Published private(set) var installed = AIVocalSeparator.installed
    enum Download: Equatable { case idle, running, failed }
    @Published private(set) var download: Download = .idle
    private var loadTask: Task<Void, Never>?

    /// Tải model (33 MB) từ huggingface.co theo commit cố định, kiểm SHA-256 từng file, biên dịch rồi đặt vào Models.
    func downloadModel() {
        guard download != .running else { return }
        download = .running
        Task.detached(priority: .userInitiated) {
            let ok = await AIModelInstaller.install()
            await MainActor.run {
                self.download = ok ? .idle : .failed
                self.installed = AIVocalSeparator.installed
                if ok, LyricsStore.shared.karaoke { self.set(true) }
            }
        }
    }

    func set(_ on: Bool) {
        loadTask?.cancel(); loadTask = nil
        guard on else {
            state = .off
            SoundCenter.shared.setAIVocals(false)
            AIVocalSeparator.model = nil
            LyricsStore.shared.resync()
            return
        }
        guard state != .on, state != .loading else { return }
        state = .loading
        loadTask = Task.detached(priority: .userInitiated) {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let model = (try? MLModel(contentsOf: AIVocalSeparator.modelURL, configuration: cfg))
                .flatMap { MDXVocals(model: $0, nFFT: AIVocalSeparator.modelFFT) }
            if let model {   // lần chạy đầu chậm (biên dịch cho ANE / GPU): chạy nháp trước khi nhạc đi qua
                let silence = [Float](repeating: 0, count: AIVocalSeparator.modelFrames)
                _ = AIVocalSeparator.separate(model, silence, silence)
            }
            await MainActor.run {
                guard !Task.isCancelled, self.state == .loading else { return }
                guard let model else { self.state = .failed; return }
                AIVocalSeparator.model = model
                self.state = .on
                SoundCenter.shared.setAIVocals(true)
                LyricsStore.shared.resync()
            }
        }
    }
}

/// Tải và cài model UVR-MDX-NET-Voc_FT (huggingface.co/gyoom/UVR-MDX-CoreML, MIT). Ghim commit + SHA-256:
/// file khác đi (bị thay, tải hỏng) thì không cài.
enum AIModelInstaller {
    static let base = "https://huggingface.co/gyoom/UVR-MDX-CoreML/resolve/aa27ab16896fdb298cdb73cceb76c950e7580c00/UVR-MDX-NET-Voc_FT.mlpackage/"
    static let files: [(path: String, sha256: String)] = [
        ("Manifest.json", "966971d49a91cbd9d43d15e40ca61e95aac72fcfe0e0acd3ece5df9818680b34"),
        ("Data/com.apple.CoreML/model.mlmodel", "bdd6a5c0b2d3d9eae431f82a58e194c43f08cc3f9da664fdb4daa9d7c4b9bc43"),
        ("Data/com.apple.CoreML/weights/weight.bin", "ee8aeba2251618d8248bfc3bbad49bb5d3b3ee0b6caa47182e08f2e5e3131c22"),
    ]

    static func install() async -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roost-mdx-\(UUID().uuidString)")
        let pkg = root.appendingPathComponent("UVR-MDX-NET-Voc_FT.mlpackage")
        defer { try? fm.removeItem(at: root) }
        do {
            for f in files {
                guard let url = URL(string: base + f.path) else { return false }
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { NSLog("[RoostAI] tải %@: HTTP lỗi", f.path); return false }
                let data = try Data(contentsOf: tmp)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == f.sha256 else { NSLog("[RoostAI] tải %@: sai SHA-256", f.path); return false }
                let dst = pkg.appendingPathComponent(f.path)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dst)
            }
            let compiled = try await MLModel.compileModel(at: pkg)
            let target = AIVocalSeparator.modelURL
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: compiled, to: target)
            NSLog("[RoostAI] đã cài model")
            return true
        } catch {
            NSLog("[RoostAI] cài model lỗi: %@", String(describing: error))
            return false
        }
    }
}
