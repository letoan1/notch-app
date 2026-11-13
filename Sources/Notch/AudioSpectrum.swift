import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Sóng nhạc thật: "nghe" riêng tiến trình Spotify / Music bằng Core Audio process tap (macOS 14.2+),
/// FFT ra 4 dải tần cho cột equalizer. Cần quyền "Ghi âm thanh hệ thống"; không có quyền thì
/// mẫu âm thanh toàn 0 → currentLevels() = nil → equalizer quay về hiệu ứng giả lập.
final class AudioSpectrum: @unchecked Sendable {
    static let shared = AudioSpectrum()
    static let bandCount = 4
    static var enabled: Bool { UserDefaults.standard.object(forKey: "realVisualizer") as? Bool ?? true }

    private let control = DispatchQueue(label: "notch.spectrum.control", qos: .userInitiated)
    private let io = DispatchQueue(label: "notch.spectrum.io", qos: .userInteractive)
    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: bandCount)
    private var lastSound: CFAbsoluteTime = 0

    // Chỉ dùng trên `control`.
    private var bundleID: String?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var retry = 0

    // Chỉ dùng trên `io`.
    private static let n = 1024
    private static let log2n = vDSP_Length(10)
    private static let edges: [Float] = [40, 160, 640, 2500, 10000]
    private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private var sampleRate: Float = 48000
    private var window = [Float](repeating: 0, count: n)
    private var ring = [Float](repeating: 0, count: n)
    private var fill = 0
    private var windowed = [Float](repeating: 0, count: n)
    private var real = [Float](repeating: 0, count: n / 2)
    private var imag = [Float](repeating: 0, count: n / 2)
    private var mags = [Float](repeating: 0, count: n / 2)
    private var peak = [Float](repeating: 1e-6, count: bandCount)
    private var smooth = [Float](repeating: 0, count: bandCount)

    private init() {
        vDSP_hann_window(&window, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
        // Đổi loa / tai nghe: dựng lại tap theo thiết bị ra mới.
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control) { [weak self] _, _ in
            guard let self, self.bundleID != nil, #available(macOS 14.2, *) else { return }
            self.stopTap()
            self.startTap()
        }
    }

    /// Mức 0…1 từng dải; nil khi không có âm thanh thật gần đây.
    func currentLevels() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - lastSound < 1.2 ? levels : nil
    }

    /// Nghe app có bundle ID này (nil = dừng).
    func follow(_ bundleID: String?) {
        control.async { [self] in
            guard bundleID != self.bundleID, #available(macOS 14.2, *) else { return }
            stopTap()
            self.bundleID = bundleID
            retry = 0
            if bundleID != nil { startTap() }
        }
    }

    // MARK: - Tap

    @available(macOS 14.2, *)
    private func startTap() {
        guard let bundleID else { return }
        let processes = Self.processObjects(matching: bundleID)
        guard !processes.isEmpty else {
            // Player chưa mở phiên âm thanh (vừa bấm play): thử lại vài lần.
            if retry < 8 {
                retry += 1
                control.asyncAfter(deadline: .now() + 1) { [self] in
                    if self.bundleID == bundleID, tapID == kAudioObjectUnknown { startTap() }
                }
            }
            return
        }
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return }
        tapID = tap

        var fmtAddr = Self.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 {
            let rate = Float(asbd.mSampleRate)
            io.async { self.sampleRate = rate }
        }

        guard let outputUID = Self.defaultOutputUID() else { stopTap(); return }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg) == noErr else { stopTap(); return }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, io) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else { stopTap(); return }
        procID = proc
        if AudioDeviceStart(agg, proc) != noErr { stopTap() }
    }

    @available(macOS 14.2, *)
    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        lock.lock()
        lastSound = 0
        lock.unlock()
    }

    // MARK: - Phân tích

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let stride = Int(max(first.mNumberChannels, 1))   // xen kẽ: lấy kênh trái
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        for i in 0..<frames {
            ring[fill] = samples[i * stride]
            fill += 1
            if fill == Self.n {
                analyze()
                fill = 0
            }
        }
    }

    private func analyze() {
        let n = Self.n
        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(n))
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        let silent = rms < 1e-4
        let binHz = sampleRate / Float(n)
        for b in 0..<Self.bandCount {
            let lo = max(1, Int(Self.edges[b] / binHz))
            let hi = min(n / 2, max(lo + 1, Int(Self.edges[b + 1] / binHz)))
            var mean: Float = 0
            mags.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + lo, 1, &mean, vDSP_Length(hi - lo)) }
            let v = sqrtf(mean)
            // Tự cân mức theo đỉnh gần đây: bài nhỏ hay to cột vẫn nhảy rõ.
            peak[b] = max(v, peak[b] * 0.996, 1e-6)
            let level = silent ? 0 : powf(min(v / peak[b], 1), 1.4)
            smooth[b] = level > smooth[b] ? smooth[b] * 0.35 + level * 0.65 : smooth[b] * 0.8 + level * 0.2
        }
        lock.lock()
        levels = smooth
        if !silent { lastSound = CFAbsoluteTimeGetCurrent() }
        lock.unlock()
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// Tiến trình âm thanh của app (kể cả helper: com.spotify.client.helper…).
    private static func processObjects(matching bundleID: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { string($0, kAudioProcessPropertyBundleID)?.hasPrefix(bundleID) == true }
    }

    private static func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }
}
