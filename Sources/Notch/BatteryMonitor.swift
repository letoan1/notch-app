import Foundation
import IOKit.ps

/// Nghe thay đổi nguồn điện qua IOKit (không poll, không cần quyền); báo khi vừa cắm sạc.
final class BatteryMonitor {
    struct Status {
        let onAC: Bool
        let percent: Int
        let charging: Bool
    }

    var onPlugIn: ((Status) -> Void)?
    /// Mọi thay đổi nguồn điện (mức pin, cắm / rút sạc).
    var onUpdate: ((Status) -> Void)?

    private var lastOnAC: Bool?
    private var source: CFRunLoopSource?

    func start() {
        lastOnAC = Self.read()?.onAC
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    private func changed() {
        guard let status = Self.read() else { return }
        defer { lastOnAC = status.onAC }
        onUpdate?(status)
        if status.onAC, lastOnAC == false { onPlugIn?(status) }
    }

    static func read() -> Status? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Status(onAC: providing == kIOPMACPowerKey,
                          percent: current * 100 / max,
                          charging: d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}
