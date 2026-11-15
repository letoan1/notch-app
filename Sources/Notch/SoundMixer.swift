import AppKit
import AudioToolbox
import Accelerate
import Combine
import CoreAudio

// Tab "Âm thanh": chọn loa / mic, âm lượng tổng, mic và âm lượng riêng từng app.
// Âm lượng từng app: process tap (macOS 14.2+) tắt tiếng app gốc rồi phát lại qua thiết bị ra với gain.
// Ở đúng 100% thì gỡ tap hẳn: không chạm đường phát, không chấm tím.

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct AudioApp: Identifiable, Equatable {
    let id: String          // bundle ID của app
    let name: String
    let pid: pid_t
    var active: Bool        // đang phát ra âm thanh
    var processes: [AudioObjectID]
}

@MainActor
final class SoundCenter: ObservableObject {
    static let shared = SoundCenter()

    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputID = AudioDeviceID(0)
    @Published private(set) var inputID = AudioDeviceID(0)
    @Published private(set) var outputVolume: Float = 0
    @Published private(set) var outputMuted = false
    @Published private(set) var outputHasVolume = false
    @Published private(set) var inputVolume: Float = 0
    @Published private(set) var inputMuted = false
    @Published private(set) var inputHasVolume = false
    @Published private(set) var apps: [AudioApp] = []
    /// Mức âm lượng từng app (1 = 100%), không tính tắt tiếng.
    @Published private(set) var gains: [String: Float] = [:]
    @Published private(set) var mutedApps: Set<String> = []
    /// Bị từ chối quyền "Ghi âm thanh hệ thống": không chỉnh được âm lượng từng app.
    @Published private(set) var permissionDenied = false
    @Published var remember: Bool {
        didSet {
            UserDefaults.standard.set(remember, forKey: Self.rememberKey)
            persist()
        }
    }

    static let maxGain: Float = 1.5
    private static let rememberKey = "sound.rememberGains"
    private static let gainsKey = "sound.appGains"
    private static let mutedKey = "sound.mutedApps"

    private let engine = VolumeEngine()
    private var started = false
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        let d = UserDefaults.standard
        remember = d.object(forKey: Self.rememberKey) as? Bool ?? true
        if remember {
            gains = (d.dictionary(forKey: Self.gainsKey) as? [String: Double] ?? [:]).mapValues { Float($0) }
            mutedApps = Set(d.stringArray(forKey: Self.mutedKey) ?? [])
        }
        engine.onDenied = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.permissionDenied = true } }
        }
    }

    /// Gọi một lần khi app chạy: chỉ đăng ký lắng nghe (không poll), áp lại mức đã nhớ.
    func start() {
        guard !started else { return }
        started = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            listen(system, CA.address(selector)) { [weak self] in self?.refreshDevices() }
        }
        if #available(macOS 14.2, *) {
            listen(system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in self?.refreshApps() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAll(rebuild: true) }
        })
        refreshDevices()
        refreshApps()
    }

    // MARK: - Thiết bị

    private var volumeListenerDevice = AudioDeviceID(0)
    private var micListenerDevice = AudioDeviceID(0)

    private func refreshDevices() {
        let all = CA.devices()
        outputs = all.filter { CA.hasStreams($0.id, output: true) && !$0.name.hasPrefix("Roost ") }
        inputs = all.filter { CA.hasStreams($0.id, output: false) && !$0.name.hasPrefix("Roost ") }
        let newOut = CA.defaultDevice(output: true)
        let newIn = CA.defaultDevice(output: false)
        let outChanged = newOut != outputID
        outputID = newOut
        inputID = newIn
        if volumeListenerDevice != newOut { watchVolume(of: newOut, output: true) }
        if micListenerDevice != newIn { watchVolume(of: newIn, output: false) }
        readVolumes()
        // Đổi loa / tai nghe: dựng lại mọi tap lên thiết bị mới.
        if outChanged { applyAll(rebuild: true) }
    }

    private func watchVolume(of device: AudioDeviceID, output: Bool) {
        let scope = output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        // Gỡ lắng nghe của thiết bị cũ cùng chiều.
        let old = output ? volumeListenerDevice : micListenerDevice
        deviceListeners.removeAll { entry in
            guard entry.0 == old, entry.1.mScope == scope else { return false }
            var addr = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &addr, .main, entry.2)
            return true
        }
        if output { volumeListenerDevice = device } else { micListenerDevice = device }
        guard device != 0 else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute,
                         kAudioDevicePropertyVolumeScalar] {
            listen(device, CA.address(selector, scope: scope)) { [weak self] in self?.readVolumes() }
        }
    }

    private func readVolumes() {
        outputHasVolume = CA.volume(outputID, output: true) != nil
        outputVolume = CA.volume(outputID, output: true) ?? 1
        outputMuted = CA.muted(outputID, output: true)
        inputHasVolume = CA.volume(inputID, output: false) != nil
        inputVolume = CA.volume(inputID, output: false) ?? 0
        inputMuted = CA.muted(inputID, output: false)
    }

    func setOutputDevice(_ id: AudioDeviceID) { CA.setDefaultDevice(id, output: true) }
    func setInputDevice(_ id: AudioDeviceID) { CA.setDefaultDevice(id, output: false) }

    func setOutputVolume(_ v: Float) {
        let v = min(max(v, 0), 1)
        outputVolume = v
        CA.setVolume(outputID, output: true, v)
        if outputMuted, v > 0 { CA.setMuted(outputID, output: true, false) }
    }

    func setInputVolume(_ v: Float) {
        let v = min(max(v, 0), 1)
        inputVolume = v
        CA.setVolume(inputID, output: false, v)
    }

    func toggleOutputMute() { CA.setMuted(outputID, output: true, !outputMuted); readVolumes() }
    func toggleInputMute() { CA.setMuted(inputID, output: false, !inputMuted); readVolumes() }

    var outputName: String { outputs.first { $0.id == outputID }?.name ?? L("Không có loa", "No output") }

    // MARK: - App

    private func refreshApps() {
        guard #available(macOS 14.2, *) else { return }
        let own = Bundle.main.bundleIdentifier ?? ""
        var byApp: [String: AudioApp] = [:]
        let regular = NSWorkspace.shared.runningApplications
        for obj in CA.processObjects() {
            let pid = CA.pid(obj)
            guard pid > 0, let app = Self.owner(of: pid, bundleID: CA.string(obj, kAudioProcessPropertyBundleID), in: regular),
                  let bid = app.bundleIdentifier, bid != own else { continue }
            let running = CA.isRunningOutput(obj)
            if processListeners[obj] == nil { watchProcess(obj) }
            if var existing = byApp[bid] {
                existing.processes.append(obj)
                existing.active = existing.active || running
                byApp[bid] = existing
            } else {
                byApp[bid] = AudioApp(id: bid, name: app.localizedName ?? bid, pid: app.processIdentifier,
                                      active: running, processes: [obj])
            }
        }
        // Bỏ lắng nghe các tiến trình đã mất.
        let alive = Set(byApp.values.flatMap(\.processes))
        for (obj, block) in processListeners where !alive.contains(obj) {
            var addr = CA.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(obj, &addr, .main, block)
            processListeners[obj] = nil
        }
        // Hiện app đang phát, hoặc đã chỉnh khác 100% / tắt tiếng.
        let shown = byApp.values.filter { $0.active || gain(for: $0.id) != 1 || mutedApps.contains($0.id) }
        let sorted = shown.sorted { ($0.active ? 0 : 1, $0.name) < ($1.active ? 0 : 1, $1.name) }
        if sorted != apps { apps = sorted }
        // App đã thoát mà không nhớ mức: bỏ luôn.
        if !remember {
            let running = Set(byApp.keys)
            gains = gains.filter { running.contains($0.key) }
            mutedApps = mutedApps.filter { running.contains($0) }
        }
        allProcesses = byApp
        applyAll(rebuild: false)
    }

    private var allProcesses: [String: AudioApp] = [:]

    private func watchProcess(_ obj: AudioObjectID) {
        var addr = CA.address(kAudioProcessPropertyIsRunningOutput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshApps() }
        }
        if AudioObjectAddPropertyListenerBlock(obj, &addr, .main, block) == noErr { processListeners[obj] = block }
    }

    /// App chủ của một tiến trình âm thanh (helper của Chrome, tiến trình GPU của WebKit…).
    private static func owner(of pid: pid_t, bundleID: String?, in running: [NSRunningApplication]) -> NSRunningApplication? {
        let responsible = Responsible.pid(for: pid)
        if let app = running.first(where: { $0.processIdentifier == responsible }), app.activationPolicy != .prohibited {
            return app
        }
        if let app = running.first(where: { $0.processIdentifier == pid }), app.activationPolicy == .regular { return app }
        guard let bundleID else { return nil }
        return running.first { app in
            guard let bid = app.bundleIdentifier, app.activationPolicy == .regular else { return false }
            return bundleID.hasPrefix(bid)
        }
    }

    func gain(for app: String) -> Float { gains[app] ?? 1 }
    func isMuted(_ app: String) -> Bool { mutedApps.contains(app) }

    func setGain(_ value: Float, for app: String) {
        var v = min(max(value, 0), Self.maxGain)
        if abs(v - 1) < 0.02 { v = 1 }   // hít về 100% để gỡ tap
        if v == 1 { gains[app] = nil } else { gains[app] = v }
        if v > 0 { mutedApps.remove(app) }
        permissionDenied = false
        persist()
        apply(app)
    }

    func toggleMute(_ app: String) {
        if mutedApps.contains(app) { mutedApps.remove(app) } else { mutedApps.insert(app) }
        permissionDenied = false
        persist()
        apply(app)
    }

    func reset(_ app: String) {
        gains[app] = nil
        mutedApps.remove(app)
        persist()
        apply(app)
    }

    private func effectiveGain(_ app: String) -> Float { mutedApps.contains(app) ? 0 : gain(for: app) }

    private func apply(_ app: String, rebuild: Bool = false) {
        guard #available(macOS 14.2, *) else { return }
        let processes = allProcesses[app]?.processes ?? []
        let uid = outputs.first { $0.id == outputID }?.uid
        engine.set(app: app, gain: effectiveGain(app), processes: processes,
                   outputID: outputID, outputUID: uid, rebuild: rebuild)
    }

    private func applyAll(rebuild: Bool) {
        let keys = Set(gains.keys).union(mutedApps).union(engine.activeApps)
        for app in keys { apply(app, rebuild: rebuild) }
    }

    private func persist() {
        let d = UserDefaults.standard
        if remember {
            d.set(gains.mapValues { Double($0) }, forKey: Self.gainsKey)
            d.set(Array(mutedApps), forKey: Self.mutedKey)
        } else {
            d.removeObject(forKey: Self.gainsKey)
            d.removeObject(forKey: Self.mutedKey)
        }
    }

    private func listen(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ action: @escaping @MainActor () -> Void) {
        var addr = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(obj, &addr, .main, block) == noErr {
            deviceListeners.append((obj, address, block))
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Tap từng app

/// Giữ các tap đang chạy. Tạo / huỷ trên hàng đợi riêng (tạo thiết bị gộp mất ~100 ms).
final class VolumeEngine: @unchecked Sendable {
    private let control = DispatchQueue(label: "roost.volume.control", qos: .userInitiated)
    /// Giá trị là AppVolumeTap (macOS 14.2+); để AnyObject vì app còn chạy trên macOS 14.0.
    private var taps: [String: AnyObject] = [:]
    private let lock = NSLock()
    private var appsSnapshot: Set<String> = []
    var onDenied: (() -> Void)?

    var activeApps: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return appsSnapshot
    }

    func set(app: String, gain: Float, processes: [AudioObjectID], outputID: AudioDeviceID, outputUID: String?, rebuild: Bool) {
        control.async { [self] in
            guard #available(macOS 14.2, *) else { return }
            if gain == 1 || processes.isEmpty || outputUID == nil {
                (taps.removeValue(forKey: app) as? AppVolumeTap)?.stop()
                snapshot()
                return
            }
            if let tap = taps[app] as? AppVolumeTap, !rebuild, tap.processes == Set(processes), tap.outputID == outputID {
                tap.setGain(gain)
                return
            }
            (taps.removeValue(forKey: app) as? AppVolumeTap)?.stop()
            guard let tap = AppVolumeTap(processes: processes, outputID: outputID, outputUID: outputUID!, gain: gain) else {
                snapshot()
                return
            }
            taps[app] = tap
            snapshot()
            // Không có quyền thì tap chỉ nhận im lặng mà app gốc vẫn bị tắt tiếng: phát hiện rồi gỡ ngay.
            control.asyncAfter(deadline: .now() + 2.5) { [weak self, weak tap] in
                guard let self, let tap, self.taps[app] === tap, !tap.heardSignal,
                      processes.contains(where: CA.isRunningOutput) else { return }
                tap.stop()
                self.taps[app] = nil
                self.snapshot()
                self.onDenied?()
            }
        }
    }

    private func snapshot() {
        lock.lock()
        appsSnapshot = Set(taps.keys)
        lock.unlock()
    }
}

@available(macOS 14.2, *)
final class AppVolumeTap: @unchecked Sendable {
    let processes: Set<AudioObjectID>
    let outputID: AudioDeviceID
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Chia sẻ với luồng âm thanh: chỉ đọc / ghi số 32-bit căn hàng, không khoá.
    private let target = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let current = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let heard = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    var heardSignal: Bool { heard.pointee != 0 }

    init?(processes: [AudioObjectID], outputID: AudioDeviceID, outputUID: String, gain: Float) {
        self.processes = Set(processes)
        self.outputID = outputID
        target.pointee = gain
        current.pointee = gain
        heard.pointee = 0

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { release(); return nil }
        tapID = tap

        var interleaved = true
        var tapBuffers = 1
        var fmtAddr = CA.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &asbd) == noErr {
            interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            tapBuffers = interleaved ? 1 : Int(max(asbd.mChannelsPerFrame, 1))
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Roost Volume",
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
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg) == noErr else { stop(); return nil }
        aggregateID = agg

        let target = self.target, current = self.current, heard = self.heard
        var proc: AudioDeviceIOProcID?
        // nil queue: chạy thẳng trên luồng IO thời gian thực, không cấp phát / khoá trong block.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, output, _ in
            AppVolumeTap.render(input: input, output: output, tapBuffers: tapBuffers, interleaved: interleaved,
                                target: target, current: current, heard: heard)
        }
        guard status == noErr, let proc else { stop(); return nil }
        procID = proc
        if AudioDeviceStart(agg, proc) != noErr { stop(); return nil }
    }

    func setGain(_ gain: Float) { target.pointee = gain }

    func stop() {
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
    }

    private func release() {}

    deinit {
        stop()
        target.deallocate()
        current.deallocate()
        heard.deallocate()
    }

    /// Chép tiếng của app (các buffer cuối của đầu vào) ra 2 kênh đầu của loa, nhân gain có ramp.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               tapBuffers: Int, interleaved: Bool, target: UnsafeMutablePointer<Float>,
                               current: UnsafeMutablePointer<Float>, heard: UnsafeMutablePointer<UInt32>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for buf in outList where buf.mData != nil { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
        guard inList.count >= tapBuffers else { return }
        let first = inList.count - tapBuffers

        // Nguồn trái / phải.
        var left: UnsafeMutablePointer<Float>?
        var right: UnsafeMutablePointer<Float>?
        var srcStride = 1
        var srcFrames = 0
        if interleaved {
            let b = inList[first]
            guard let d = b.mData else { return }
            let ch = Int(max(b.mNumberChannels, 1))
            srcStride = ch
            srcFrames = Int(b.mDataByteSize) / 4 / ch
            left = d.assumingMemoryBound(to: Float.self)
            right = ch > 1 ? left! + 1 : left
        } else {
            let bl = inList[first]
            guard let d = bl.mData else { return }
            left = d.assumingMemoryBound(to: Float.self)
            srcFrames = Int(bl.mDataByteSize) / 4
            right = tapBuffers > 1 ? inList[first + 1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
        }
        guard let left, let right, srcFrames > 0 else { return }

        if heard.pointee == 0 {
            var peak: Float = 0
            vDSP_maxmgv(left, vDSP_Stride(srcStride), &peak, vDSP_Length(srcFrames))
            if peak > 1e-6 { heard.pointee = 1 }
        }

        let goal = target.pointee
        let start = current.pointee
        let step = (goal - start) / Float(srcFrames)
        let boost = max(goal, start) > 1

        // Ghi ra kênh 0 và 1 của thiết bị (loa 1 kênh thì trộn L+R).
        var channel = 0
        for buf in outList {
            guard let d = buf.mData, channel < 2 else { break }
            let out = d.assumingMemoryBound(to: Float.self)
            let ch = Int(max(buf.mNumberChannels, 1))
            let frames = min(Int(buf.mDataByteSize) / 4 / ch, srcFrames)
            let mono = outList.count == 1 && ch == 1
            for c in 0..<min(ch, 2 - channel) {
                let src = (channel + c) == 0 ? left : right
                var g = start
                for i in 0..<frames {
                    var s = mono ? (left[i * srcStride] + right[i * srcStride]) * 0.5 : src[i * srcStride]
                    s *= g
                    if boost {   // soft clip khi vượt 100%
                        s = max(-1.5, min(1.5, s))
                        s = s - s * s * s / 6.75
                    }
                    out[i * ch + c] = s
                    g += step
                }
            }
            channel += ch
        }
        current.pointee = goal
    }
}

// MARK: - Core Audio

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func ids(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func devices() -> [AudioDevice] {
        ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func hasStreams(_ id: AudioDeviceID, output: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func defaultDevice(output: Bool) -> AudioDeviceID {
        var addr = address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefaultDevice(_ id: AudioDeviceID, output: Bool) {
        var addr = address(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        if output {   // âm báo hệ thống đi theo luôn
            var sys = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sys, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        }
    }

    /// Âm lượng 0…1: ưu tiên "virtual main", không có thì kênh chính hoặc trung bình kênh 1–2.
    static func volume(_ id: AudioDeviceID, output: Bool) -> Float? {
        guard id != 0 else { return nil }
        let scope = output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        for (selector, element) in [(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain),
                                    (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)] {
            var addr = address(selector, scope: scope, element: element)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
        }
        var values: [Float] = []
        for ch in [UInt32(1), 2] {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { values.append(v) }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(_ id: AudioDeviceID, output: Bool, _ value: Float) {
        guard id != 0 else { return }
        let scope = output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        var v = Float32(value)
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var addr = address(selector, scope: scope)
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(id, &addr), AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue {
                if AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr { return }
            }
        }
        for ch in [UInt32(1), 2] {
            var addr = address(kAudioDevicePropertyVolumeScalar, scope: scope, element: ch)
            if AudioObjectHasProperty(id, &addr) {
                AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            }
        }
    }

    static func muted(_ id: AudioDeviceID, output: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, scope: output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput)
        guard id != 0, AudioObjectHasProperty(id, &addr) else { return false }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    static func setMuted(_ id: AudioDeviceID, output: Bool, _ on: Bool) {
        var addr = address(kAudioDevicePropertyMute, scope: output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput)
        guard id != 0, AudioObjectHasProperty(id, &addr) else { return }
        var v: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    static func processObjects() -> [AudioObjectID] {
        guard #available(macOS 14.2, *) else { return [] }
        return ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    static func pid(_ obj: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var v = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr && v != 0
    }
}

/// Tiến trình "chịu trách nhiệm" (vd. tiến trình GPU của WebKit → Safari). API riêng của libSystem.
enum Responsible {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func pid(for pid: pid_t) -> pid_t { fn?(pid) ?? pid }
}
