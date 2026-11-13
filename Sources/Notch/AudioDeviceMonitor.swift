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
    private var lastID = AudioDeviceID(0)

    func start() {
        lastID = Self.defaultOutput()
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
        let wanted = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB]
        guard let transport = Self.transport(id), wanted.contains(transport), let name = Self.name(id) else { return }
        onConnect?(Device(name: name, symbol: Self.symbol(name: name, transport: transport)))
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
