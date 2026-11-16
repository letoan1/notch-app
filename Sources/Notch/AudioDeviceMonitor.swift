import SwiftUI
import CoreAudio
import Foundation

/// Báo khi đầu ra âm thanh mặc định chuyển sang tai nghe / loa Bluetooth hoặc USB
/// (AirPods kết nối, cắm DAC…). Dùng CoreAudio nên không cần quyền Bluetooth.
final class AudioDeviceMonitor {
    struct Device {
        let name: String
        let symbol: String
    }

    var onConnect: ((Device) -> Void)?
    /// Đầu ra hiện tại có phải tai nghe không (gọi lúc start và mỗi lần đổi đầu ra).
    var onHeadphonesChange: ((Bool) -> Void)?
    private var lastID = AudioDeviceID(0)

    func start() {
        lastID = Self.defaultOutput()
        onHeadphonesChange?(Self.isHeadphones(lastID))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.changed()
        }
    }

    private func changed() {
        let id = Self.defaultOutput()
        guard id != 0, id != lastID else { return }
        lastID = id
        onHeadphonesChange?(Self.isHeadphones(id))
        let wanted = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB]
        guard let transport = Self.transport(id), wanted.contains(transport), let name = Self.name(id) else { return }
        onConnect?(Device(name: name, symbol: Self.symbol(name: name, transport: transport)))
    }

    /// Đầu ra hiện tại nếu là thiết bị Bluetooth.
    static func bluetoothOutput() -> Device? {
        let id = defaultOutput()
        guard id != 0, let t = transport(id), t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE,
              let name = name(id) else { return nil }
        return Device(name: name, symbol: symbol(name: name, transport: t))
    }

    /// Tai nghe = Bluetooth / USB mà tên không giống loa (JBL Flip, SoundLink, HomePod…).
    private static func isHeadphones(_ id: AudioDeviceID) -> Bool {
        guard id != 0, let transport = transport(id), let name = name(id) else { return false }
        let n = name.lowercased()
        let speakerWords = ["speaker", "loa", "soundlink", "flip", "charge", "boombox", "boom", "xtreme", "go 3", "go 4",
                            "pulse", "homepod", "sonos", "soundbar", "partybox", "megaboom", "wonderboom", "clip"]
        if speakerWords.contains(where: n.contains) { return false }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return true
        case kAudioDeviceTransportTypeUSB: return ["headset", "headphone", "earphone", "tai nghe"].contains(where: n.contains)
        default: return false
        }
    }

    private static func symbol(name: String, transport: UInt32) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        return transport == kAudioDeviceTransportTypeUSB ? "hifispeaker.fill" : "headphones"
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr ? id : 0
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32? {
        var addr = address(kAudioDevicePropertyTransportType)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let name = value?.takeRetainedValue() as String?, !name.isEmpty else { return nil }
        return name
    }
}

/// % pin thiết bị Bluetooth đang kết nối, đọc một lần từ system_profiler (không cần quyền Bluetooth).
/// AirPods: lấy bên tai thấp hơn, bỏ hộp sạc.
enum BluetoothBattery {
    static func level(named name: String, completion: @escaping @Sendable (Int?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return completion(nil) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            completion(parse(data, name: name) ?? accessoryLevel(named: name))
        }
    }

    /// Tai nghe không phải của Apple (JBL, Sony…) thường không có pin trong system_profiler,
    /// nhưng macOS vẫn biết qua phụ kiện nguồn điện: đọc `pmset -g accps` (~0,2s, cùng lượt đọc nền).
    static func accessoryLevel(named name: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "accps"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseAccps(String(decoding: data, as: UTF8.self), name: name)
    }

    /// Dòng dạng " -JBL Wave Beam 2 (id=27857825)\t80%; discharging present: true".
    static func parseAccps(_ text: String, name: String) -> Int? {
        let wanted = name.lowercased()
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("-"), let idRange = t.range(of: " (id=") else { continue }
            let n = t[t.index(after: t.startIndex)..<idRange.lowerBound].lowercased()
            guard n == wanted || n.contains(wanted) || wanted.contains(n),
                  let pct = t.range(of: #"\d+%"#, options: .regularExpression) else { continue }
            return Int(t[pct].dropLast())
        }
        return nil
    }

    static func parse(_ data: Data, name: String) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let wanted = name.lowercased()
        for c in controllers {
            for entry in c["device_connected"] as? [[String: Any]] ?? [] {
                for (key, value) in entry {
                    let k = key.lowercased()
                    guard k == wanted || wanted.contains(k) || k.contains(wanted), let info = value as? [String: Any] else { continue }
                    func pct(_ field: String) -> Int? {
                        (info[field] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                    }
                    if let main = pct("device_batteryLevelMain") { return main }
                    let ears = [pct("device_batteryLevelLeft"), pct("device_batteryLevelRight")].compactMap { $0 }
                    if let low = ears.min() { return low }
                    return nil
                }
            }
        }
        return nil
    }
}

/// Tai nghe / loa Bluetooth đang là đầu ra và % pin của nó. Đọc lại khi đổi đầu ra và khi notch mở.
@MainActor
final class BluetoothAudio: ObservableObject {
    static let shared = BluetoothAudio()
    @Published private(set) var name: String?
    @Published private(set) var symbol: String?
    @Published private(set) var level: Int?
    private var lastRead = Date.distantPast

    func refresh(force: Bool = true) {
        guard let device = AudioDeviceMonitor.bluetoothOutput() else {
            name = nil; symbol = nil; level = nil
            return
        }
        if device.name != name { level = nil }
        name = device.name
        symbol = device.symbol
        // system_profiler ~0.2s: không đọc dồn dập khi notch mở/đóng liên tục.
        guard force || Date().timeIntervalSince(lastRead) > 30 else { return }
        lastRead = Date()
        BluetoothBattery.level(named: device.name) { value in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard BluetoothAudio.shared.name == device.name else { return }
                    BluetoothAudio.shared.level = value
                }
            }
        }
    }
}

/// Vòng pin nhỏ cho nút tròn: % ở giữa, chưa đọc được thì icon tai nghe.
struct HeadphoneBatteryGlyph: View {
    @ObservedObject var audio = BluetoothAudio.shared
    let size: CGFloat
    let track: Color
    let ink: Color

    var body: some View {
        Group {
            if let level = audio.level {
                let color = level <= 20 ? Color(red: 1, green: 0.3, blue: 0.3) : Color(red: 0.3, green: 0.85, blue: 0.4)
                ZStack {
                    Circle().stroke(track, lineWidth: 2.5)
                    Circle().trim(from: 0, to: CGFloat(level) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(level)").font(.ui(8.5, weight: .bold).monospacedDigit()).foregroundStyle(ink)
                }
                .frame(width: size, height: size)
            } else {
                Image(systemName: audio.symbol ?? "headphones")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ink)
            }
        }
        .onAppear { audio.refresh(force: false) }
    }
}
