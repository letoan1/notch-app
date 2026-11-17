import AppKit
import AVFoundation
import CoreAudio
import CoreML
import Foundation

/// Tự kiểm karaoke trên một file nhạc, chạy đúng hàm render của tap (AppVolumeTap.render) với bộ đệm giống tap thật:
///   Roost --karaoke-selftest <file nhạc> <thư mục ra>
/// In số đo (đoạn mất tiếng, giọng còn lại, beat giữ được) và ghi WAV để nghe. Không mở giao diện, chạy xong thoát.
enum KaraokeSelfTest {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--karaoke-selftest"), a.count > i + 2 else { return }
        if #available(macOS 14.2, *) {
            run(URL(fileURLWithPath: a[i + 1]), out: URL(fileURLWithPath: a[i + 2]))
        }
        exit(0)
    }

    /// Roost --tap-selftest [--no-ai]: chạy trong Roost.app (có quyền ghi âm thanh hệ thống) để bắt tap Spotify thật
    /// 20 s với giọng ca sĩ 0%, log mức vào / ra mỗi giây và mỗi lần dựng / gỡ tap ([RoostTap]), rồi trả Spotify như cũ.
    static func runTapTestIfRequested() {
        guard CommandLine.arguments.contains("--tap-selftest") else { return }
        guard #available(macOS 14.2, *) else { exit(0) }
        let useAI = !CommandLine.arguments.contains("--no-ai")
        // NSLog của app không vào log hệ thống: ghi stderr ra file để đọc lại.
        let logPath = NSHomeDirectory() + "/Library/Logs/Roost-tap-selftest.log"
        freopen(logPath, "w", stderr)
        AppVolumeTap.meterLog = true
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func spotify(_ cmd: String) -> String? {
            NSAppleScript(source: "tell application \"Spotify\" to \(cmd)")?.executeAndReturnError(nil).stringValue
        }
        MainActor.assumeIsolated {
            let was = spotify("player state as string")
            NSLog("[RoostTap] tự kiểm (%@): Spotify đang %@", useAI ? "AI" : "lọc phổ", was ?? "?")
            _ = spotify("play")
            spin(2)
            let sc = SoundCenter.shared
            sc.start()
            spin(1)
            if CommandLine.arguments.contains("--flow") {
                // Đúng luồng của app: NowPlaying → LyricsStore → bật Karaoke (nạp AI) → kéo thanh về 0.
                let media = NowPlaying()
                let store = LyricsStore.shared
                store.bind(media); store.attach()
                for _ in 0..<20 where media.track?.bundleID != "com.spotify.client" { spin(0.5) }
                NSLog("[RoostTap] luồng app: bài %@ (%@)", media.track?.title ?? "?", media.track?.bundleID ?? "?")
                store.karaoke = true
                for _ in 0..<40 where AIVocals.shared.state != .on { spin(0.5) }
                NSLog("[RoostTap] luồng app: AI %@", String(describing: AIVocals.shared.state))
                store.vocalLevel = 0
                spin(20)
                NSLog("[RoostTap] luồng app: kéo về 100%%, tắt Karaoke")
                store.vocalLevel = 1
                store.karaoke = false
                spin(2)
                if was != "playing" { _ = spotify("pause") }
                NSLog("[RoostTap] tự kiểm xong")
                exit(0)
            }
            if useAI, AIVocalSeparator.installed {
                let cfg = MLModelConfiguration(); cfg.computeUnits = .all
                if let m = (try? MLModel(contentsOf: AIVocalSeparator.modelURL, configuration: cfg))
                    .flatMap({ MDXVocals(model: $0, nFFT: AIVocalSeparator.modelFFT) }) {
                    let z = [Float](repeating: 0, count: MDXVocals.frames)
                    _ = m.vocals(z, z)
                    AIVocalSeparator.model = m
                    sc.setAIVocals(true)
                }
            }
            sc.setVocalCut(0, app: "com.spotify.client")   // bật Karaoke: tap gắn sẵn ở mức 0
            spin(6)
            for (cut, secs) in [(1.0, 4.0), (0.0, 3.0), (1.0, 4.0), (0.55, 3.0)] as [(Float, Double)] {
                NSLog("[RoostTap] kéo thanh: bỏ giọng %.0f%%", cut * 100)
                sc.setVocalCut(cut, app: "com.spotify.client")
                spin(secs)
            }
            sc.setAIVocals(false)
            sc.setVocalCut(0, app: "com.spotify.client")
            spin(1)
            if was != "playing" { _ = spotify("pause") }
            NSLog("[RoostTap] tự kiểm xong")
        }
        exit(0)
    }

    struct Audio { var l: [Float]; var r: [Float]; var rate: Double }

    static func load(_ url: URL) -> Audio? {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = buf.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return Audio(l: l, r: r, rate: f.processingFormat.sampleRate)
    }

    static func write(_ l: [Float], _ r: [Float], rate: Double, to url: URL) {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                          interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count)) else { return }
        buf.frameLength = AVAudioFrameCount(l.count)
        l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: l.count) }
        r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: r.count) }
        try? file.write(from: buf)
    }

    /// Cho `seconds` giây nhạc qua render (khối 1024 mẫu, vào / ra stereo xen kẽ như tap). `cut(t)` = mức bỏ giọng
    /// theo giây; `pace` > 0 thì giữ nhịp (lần thời gian thực) cho luồng AI kịp chạy.
    @available(macOS 14.2, *)
    static func pass(_ a: Audio, seconds: Double, cut: (Double) -> Float, ai: AIVocalSeparator?,
                     pace: Double = 0) -> (l: [Float], r: [Float], delay: Int) {
        let total = min(a.l.count, Int(seconds * a.rate))
        let target = UnsafeMutablePointer<Float>.allocate(capacity: 1); target.pointee = 1
        let current = UnsafeMutablePointer<Float>.allocate(capacity: 1); current.pointee = 1
        let heard = UnsafeMutablePointer<UInt32>.allocate(capacity: 1); heard.pointee = 0
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 2 * AppVolumeTap.scratchFrames)
        let block = 1024
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: 2 * block)
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: 2 * block)
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer {
            target.deallocate(); current.deallocate(); heard.deallocate(); scratch.deallocate()
            inData.deallocate(); outData.deallocate(); free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer)
        }
        ai?.setEnabled(true)
        var oL = [Float](repeating: 0, count: total), oR = oL
        let t0 = Date()
        var i = 0
        while i < total {
            let f = min(block, total - i)
            for k in 0..<f { inData[2 * k] = a.l[i + k]; inData[2 * k + 1] = a.r[i + k] }
            inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(f * 8), mData: inData)
            outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(f * 8), mData: outData)
            let c = cut(Double(i) / a.rate)
            ai?.level.pointee = c
            AppVolumeTap.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer, tapBuffers: 1,
                                interleaved: true, target: target, current: current, heard: heard,
                                ai: ai, scratch: scratch)
            for k in 0..<f { oL[i + k] = outData[2 * k]; oR[i + k] = outData[2 * k + 1] }
            i += f
            if pace > 0 {
                let wait = t0.addingTimeInterval(Double(i) / a.rate / pace).timeIntervalSinceNow
                if wait > 0 { usleep(useconds_t(wait * 1e6)) }
            }
        }
        ai?.setEnabled(false)
        return (oL, oR, ai?.delay ?? 0)
    }

    /// Giọng tham chiếu: cùng model chạy offline cả bài, cửa sổ chồng 50% trộn tam giác (cách tốt nhất khi
    /// không bị giới hạn thời gian), để đo bản chạy thời gian thực.
    static func referenceVocals(_ a: Audio, model: MDXVocals) -> (l: [Float], r: [Float]) {
        let w = MDXVocals.frames, step = w / 2
        var vl = [Float](repeating: 0, count: a.l.count), vr = vl, ws = vl
        var s = -step
        while s < a.l.count {
            var cl = [Float](repeating: 0, count: w), cr = cl
            for k in 0..<w where s + k >= 0 && s + k < a.l.count { cl[k] = a.l[s + k]; cr[k] = a.r[s + k] }
            if let v = model.vocals(cl, cr) {
                for k in 0..<w where s + k >= 0 && s + k < a.l.count {
                    let tri = Float(1 - abs(Double(k) / Double(w) * 2 - 1)) + 1e-3
                    vl[s + k] += v.l[k] * tri; vr[s + k] += v.r[k] * tri; ws[s + k] += tri
                }
            }
            s += step
        }
        for k in 0..<vl.count where ws[k] > 0 { vl[k] /= ws[k]; vr[k] /= ws[k] }
        return (vl, vr)
    }

    static func rms(_ x: [Float], _ from: Int, _ to: Int) -> Double {
        guard to > from else { return 0 }
        var e = 0.0
        for k in from..<to { e += Double(x[k]) * Double(x[k]) }
        return (e / Double(to - from)).squareRoot()
    }

    static func db(_ x: Double) -> String { String(format: "%+.1f dB", 20 * log10(max(x, 1e-9))) }

    /// In: các giây bị mất tiếng; nếu có giọng tham chiếu: giọng còn lại và beat giữ được (so với nhạc nền tham chiếu).
    static func report(_ name: String, _ a: Audio, _ o: (l: [Float], r: [Float], delay: Int), from: Double, to: Double,
                       ref: (l: [Float], r: [Float])?) {
        let d = o.delay, sec = Int(a.rate)
        var silent: [Int] = []
        for s in Int(from)..<Int(to) {
            let a0 = s * sec, a1 = a0 + sec
            guard a1 + d <= o.l.count else { break }
            let inR = rms(a.l, a0, a1)
            let outR = rms(o.l, a0 + d, a1 + d)
            if inR > 0.01, outR < inR * 0.1 { silent.append(s) }
        }
        var line = "\(name): giây mất tiếng \(silent.isEmpty ? "không có" : silent.map(String.init).joined(separator: ","))"
        if let ref {
            var eV = 0.0, eRes = 0.0, eAcc = 0.0, eOut = 0.0
            for k in Int(from * a.rate)..<min(Int(to * a.rate), o.l.count - d) {
                let acc = Double(a.l[k] - ref.l[k]), out = Double(o.l[k + d])
                eV += Double(ref.l[k]) * Double(ref.l[k]); eAcc += acc * acc; eOut += out * out
                eRes += (out - acc) * (out - acc)
            }
            line += " | sai khác so với nhạc nền (giọng sót + vệt): " + db((eRes / max(eV, 1e-12)).squareRoot())
                + " | độ to so với nhạc nền: " + db((eOut / max(eAcc, 1e-12)).squareRoot())
        }
        print(line)
    }

    @available(macOS 14.2, *)
    static func run(_ url: URL, out: URL) {
        guard let a = load(url) else { print("không đọc được \(url.path)"); return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print(String(format: "file: %.1f s, %.0f Hz", Double(a.l.count) / a.rate, a.rate))

        var model: MDXVocals?
        if AIVocalSeparator.installed {
            let cfg = MLModelConfiguration(); cfg.computeUnits = .all
            model = (try? MLModel(contentsOf: AIVocalSeparator.modelURL, configuration: cfg))
                .flatMap { MDXVocals(model: $0, nFFT: AIVocalSeparator.modelFFT) }
        }
        let ref = model.map { referenceVocals(a, model: $0) }
        if ref == nil { print("không có model AI: bỏ phần đo so với nhạc nền") }
        let seconds = min(Double(a.l.count) / a.rate, 90)

        // AI: giữ nhịp thời gian thực như app (KARAOKE_PACE=2 để chạy nhanh hơn).
        if let model {
            AIVocalSeparator.model = model
            let silence = [Float](repeating: 0, count: AIVocalSeparator.modelFrames)
            _ = AIVocalSeparator.separate(model, silence, silence)   // làm nóng GPU như app
            let sep = AIVocalSeparator(sampleRate: a.rate)
            let pace = Double(ProcessInfo.processInfo.environment["KARAOKE_PACE"] ?? "") ?? 1
            let t0 = Date()
            let o = pass(a, seconds: 60, cut: { $0 < 30 ? 1 : 0.85 }, ai: sep, pace: pace)
            print(String(format: "AI: 60 s nhạc chạy hết %.1f s", Date().timeIntervalSince(t0)))
            report("AI, 0% (10–30 s)", a, o, from: 10, to: 30, ref: ref)
            report("AI, 15% (30–55 s)", a, o, from: 30, to: 55, ref: ref)
            write(Array(o.l.dropFirst(o.delay)), Array(o.r.dropFirst(o.delay)), rate: a.rate,
                  to: out.appendingPathComponent("1-ai.wav"))
        }
        if let ref {
            let n = Int(seconds * a.rate)
            write(Array(zip(a.l, ref.l).map { $0 - $1 }.prefix(n)), Array(zip(a.r, ref.r).map { $0 - $1 }.prefix(n)),
                  rate: a.rate, to: out.appendingPathComponent("2-nhac-nen-tham-chieu.wav"))
        }
        print("đã ghi WAV vào \(out.path)")
    }
}
