import Darwin
import Foundation
import IOKit

/// Số liệu cho tab Hệ thống. Chỉ đo khi có view đang xem (`retain` / `release`):
/// không ai xem thì không có timer nào chạy.
@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    struct Snapshot: Equatable {
        var cpu: Double?               // 0...1
        var cores = ProcessInfo.processInfo.processorCount
        var memUsed: UInt64 = 0
        var memTotal = ProcessInfo.processInfo.physicalMemory
        var batteryPercent: Int?       // nil = máy không có pin
        var batteryWatts: Double?      // dương: đang sạc, âm: đang xả
        var batteryOnAC = false
        var down: Double?              // byte/giây
        var up: Double?
        var diskFree: Int64?
        var diskTotal: Int64?
        var thermal: ProcessInfo.ThermalState = .nominal
    }

    @Published private(set) var snapshot = Snapshot()

    static let interval: TimeInterval = 1.5
    private var demand = 0
    private var timer: Timer?
    private var tick = 0
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNet: (down: [String: UInt32], up: [String: UInt32], at: TimeInterval)?

    func retain() {
        demand += 1
        guard demand == 1 else { return }
        tick = 0
        lastCPU = nil
        lastNet = nil
        sample()
        // Lần đo đầu chưa có chênh lệch CPU / mạng: đo lại sớm để số hiện nhanh.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.demand > 0 else { return }
                self.sample()
                self.startTimer()
            }
        }
    }

    func release() {
        demand = max(0, demand - 1)
        if demand == 0 { timer?.invalidate(); timer = nil }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        var s = snapshot
        s.cpu = readCPU()
        if let m = Self.readMemory() { s.memUsed = m }
        let battery = BatteryMonitor.read()
        s.batteryPercent = battery?.percent
        s.batteryOnAC = battery?.onAC ?? false
        s.batteryWatts = battery == nil ? nil : Self.readBatteryWatts()
        let net = readNetwork()
        s.down = net?.down
        s.up = net?.up
        // Dung lượng ổ đĩa đổi chậm: đọc lần đầu rồi mỗi ~15 giây.
        if tick % 10 == 0, let d = Self.readDisk() { s.diskFree = d.free; s.diskTotal = d.total }
        s.thermal = ProcessInfo.processInfo.thermalState
        tick += 1
        if s != snapshot { snapshot = s }
    }

    // MARK: - Nguồn số liệu

    private func readCPU() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total, busy >= last.busy else { return nil }
        return min(1, Double(busy - last.busy) / Double(total - last.total))
    }

    /// Giống Activity Monitor: bộ nhớ app + wired + nén.
    private static func readMemory() -> UInt64? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// Công suất pin (W) từ AppleSmartBattery: Voltage (mV) × Amperage (mA).
    private static func readBatteryWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        }
        guard let mv = number("Voltage")?.doubleValue, let ma = number("Amperage")?.int64Value else { return nil }
        return mv * Double(ma) / 1_000_000
    }

    /// Tổng byte vào / ra của các interface vật lý đang chạy (Wi‑Fi, Ethernet, mạng di động).
    private func readNetwork() -> (down: Double, up: Double)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var down: [String: UInt32] = [:], up: [String: UInt32] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            down[name] = data.pointee.ifi_ibytes
            up[name] = data.pointee.ifi_obytes
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastNet = (down, up, now) }
        guard let last = lastNet, now - last.at > 0.2 else { return nil }
        // Bộ đếm 32 bit: trừ kiểu tràn số vẫn đúng khi bộ đếm quay vòng.
        func delta(_ cur: [String: UInt32], _ old: [String: UInt32]) -> Double {
            cur.reduce(0) { sum, kv in sum + Double(old[kv.key].map { kv.value &- $0 } ?? 0) }
        }
        let dt = now - last.at
        return (delta(down, last.down) / dt, delta(up, last.up) / dt)
    }

    private static func readDisk() -> (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (free, Int64(total))
    }
}

// MARK: - Định dạng

extension SystemStats {
    static func gb(_ bytes: UInt64) -> String {
        let v = Double(bytes) / 1_073_741_824
        return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    /// Byte/giây → ("2.4", "MB/s").
    static func rate(_ bps: Double) -> (value: String, unit: String) {
        if bps >= 1_000_000 {
            let v = bps / 1_000_000
            return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v), "MB/s")
        }
        if bps >= 1_000 { return (String(format: "%.0f", bps / 1_000), "KB/s") }
        return (String(format: "%.0f", bps), "B/s")
    }

    static func diskSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.0f GB", gb)
    }
}
