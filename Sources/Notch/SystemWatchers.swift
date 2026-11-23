import AppKit
import Carbon
import Network

// MARK: - Pin yếu / pin đầy

/// Nghe nguồn điện qua IOKit (sự kiện, không poll): báo pin yếu ở 20% và 10% (mỗi mốc một lần
/// mỗi lượt xả), báo pin đầy khi tới 100% hoặc khi macOS dừng sạc ở mức tối ưu.
@MainActor
final class BatteryAlerts {
    private let monitor = BatteryMonitor()
    private var warned20 = false
    private var warned10 = false
    private var wasCharging: Bool?
    private var notifiedFull = false

    func start() {
        // Mở app lúc đang ở mức thấp: không báo ngay, chỉ báo khi xuống mốc kế tiếp.
        if let s = BatteryMonitor.read() {
            if !s.onAC {
                warned20 = s.percent <= 20
                warned10 = s.percent <= 10
            } else {
                notifiedFull = s.percent >= 100 || !s.charging
            }
            wasCharging = s.charging
        }
        monitor.onUpdate = { [weak self] status in
            MainActor.assumeIsolated { self?.handle(status) }
        }
        monitor.start()
    }

    private func handle(_ s: BatteryMonitor.Status) {
        defer { wasCharging = s.charging }
        guard AlertSettings.shared.battery else { return }
        if s.onAC {
            warned20 = false
            warned10 = false
            AlertCenter.shared.dismiss(.lowBattery)
            let stoppedAtLimit = !s.charging && wasCharging == true && s.percent >= 80
            if !notifiedFull, s.percent >= 100 || stoppedAtLimit {
                notifiedFull = true
                AlertCenter.shared.post(NotchAlert(
                    kind: .batteryFull,
                    title: s.percent >= 100 ? L("Pin đã đầy", "Battery full") : L("Đã sạc tới", "Charged to"),
                    highlight: s.percent >= 100 ? nil : "\(s.percent)%",
                    subtitle: s.percent >= 100 ? L("Bạn có thể rút sạc.", "You can unplug the charger.")
                                               : L("macOS dừng ở mức này để pin bền hơn.", "macOS holds the charge here to protect the battery."),
                    icon: .battery(Double(s.percent) / 100), tone: .green, priority: 0, duration: 4, action: .none))
            }
        } else {
            notifiedFull = false
            let level: Int? = s.percent <= 10 && !warned10 ? 10 : s.percent <= 20 && !warned20 ? 20 : nil
            guard let level else { return }
            warned20 = true
            if level == 10 { warned10 = true }
            AlertCenter.shared.post(NotchAlert(
                kind: .lowBattery,
                title: L("Pin yếu", "Battery low"), highlight: "\(s.percent)%",
                subtitle: L("Bật Chế độ nguồn điện thấp hoặc cắm sạc.", "Turn on Low Power Mode or plug in your charger."),
                icon: .battery(Double(s.percent) / 100), tone: .red,
                priority: level == 10 ? 2 : 1, duration: level == 10 ? 9 : 6, action: .batterySettings))
        }
    }
}

// MARK: - Mất mạng

/// NWPathMonitor: chỉ báo khi mất mạng quá 4 giây (Wi-Fi chập chờn thoáng qua thì im).
/// Vừa thức dậy từ ngủ thì đợi lâu hơn vì Wi-Fi cần vài giây để nối lại.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var online: Bool?
    private var pending: DispatchWorkItem?
    private var shownLost = false
    private var quietUntil = Date.distantPast

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietUntil = Date().addingTimeInterval(20) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let kind = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.update(ok: ok, interface: kind) }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func update(ok: Bool, interface: String) {
        defer { online = ok }
        guard let was = online else { return }   // lần đọc đầu: chỉ ghi nhận
        if ok {
            if !was { ChirpClient.shared.networkBack() }
            pending?.cancel()
            pending = nil
            if shownLost {
                shownLost = false
                AlertCenter.shared.dismiss(.networkLost)
                guard AlertSettings.shared.network else { return }
                AlertCenter.shared.post(NotchAlert(
                    kind: .networkBack, title: L("Đã có mạng lại", "Back online"), highlight: nil,
                    subtitle: interface == "wifi" ? L("Đang dùng Wi-Fi.", "Using Wi-Fi.")
                        : interface == "ethernet" ? L("Đang dùng mạng dây.", "Using Ethernet.") : L("Kết nối Internet đã ổn.", "Your Internet connection is back."),
                    icon: .symbol("antenna.radiowaves.left.and.right"), tone: .green,
                    priority: 0, duration: 2.5, action: .none))
            }
        } else if was, pending == nil {
            let delay = max(4, quietUntil.timeIntervalSinceNow)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.lostConfirmed() }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func lostConfirmed() {
        pending = nil
        guard online == false, AlertSettings.shared.network else { return }
        shownLost = true
        AlertCenter.shared.post(NotchAlert(
            kind: .networkLost, title: L("Mất kết nối Internet", "No Internet connection"), highlight: nil,
            subtitle: L("Kết nối Wi-Fi, Ethernet hoặc Personal Hotspot để tiếp tục.", "Connect to Wi-Fi, Ethernet, or Personal Hotspot to continue."),
            icon: .symbol("antenna.radiowaves.left.and.right.slash"), tone: .red,
            priority: 2, duration: 8, action: .networkSettings))
    }
}

// MARK: - Caps Lock

/// Caps Lock đổi trạng thái → báo ON / OFF.
/// - Có quyền Trợ năng: global monitor flagsChanged (tức thì, theo sự kiện).
/// - Không có quyền: đọc NSEvent.modifierFlags (không cần quyền) mỗi khi notch nhận sự kiện chuột,
///   nên sẽ báo trễ tới lần di chuột kế tiếp. Không thêm timer nào.
@MainActor
final class CapsLockWatcher {
    var onChange: ((Bool) -> Void)?
    private var last = NSEvent.modifierFlags.contains(.capsLock)
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.report(on) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.report(on) }
            return event
        }
    }

    /// Gọi từ vòng xử lý chuột của notch (đường dự phòng khi chưa có quyền Trợ năng).
    func check() { report(NSEvent.modifierFlags.contains(.capsLock)) }

    private func report(_ on: Bool) {
        guard on != last else { return }
        last = on
        guard AlertSettings.shared.capsLock else { return }
        onChange?(on)
    }
}

// MARK: - Bộ gõ V/E

/// Bộ gõ tiếng Việt có sẵn của macOS (Telex, VNI...) bật hay tắt. Nghe thông báo đổi bộ gõ của hệ thống,
/// không poll. Chỉ báo khi chuyển giữa Việt và không Việt (đổi hai bàn phím tiếng Anh thì im).
@MainActor
final class InputSourceWatcher {
    var onChange: ((Bool) -> Void)?
    private var last = InputSourceWatcher.isVietnamese()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
    }

    private func report() {
        let vi = Self.isVietnamese()
        guard vi != last else { return }
        last = vi
        guard AlertSettings.shared.inputSource else { return }
        onChange?(vi)
    }

    /// Ngôn ngữ đầu tiên của bộ gõ hiện tại là "vi", hoặc mã bộ gõ là của VietnameseIM.
    static func isVietnamese() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first, first.hasPrefix("vi") {
            return true
        }
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            return id.contains("Vietnamese")
        }
        return false
    }
}

// MARK: - File tải về

/// Theo dõi ~/Downloads bằng FSEvents (theo sự kiện, CPU ~0 khi rảnh). File chỉ được thêm khi đã tải xong:
/// bỏ file ẩn, file tạm (.crdownload, .download, .part…), thư mục; đợi dung lượng đứng yên.
/// Chỉ nhận file vừa được tạo (có cờ quarantine của trình duyệt hoặc tạo trong 10 phút gần đây),
/// nên kéo một file cũ vào Downloads không bị tính là tải về.
@MainActor
final class DownloadsWatcher {
    var onFile: ((URL) -> Void)?
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var seen: Set<String> = []
    private let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].standardizedFileURL.path

    private static let tempExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "filepart"]

    func setEnabled(_ on: Bool) {
        if on, stream == nil { start() } else if !on { stop() }
    }

    private func start() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { for p in list.prefix(count) { watcher.consider(p) } }
        }, &ctx, [dir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func consider(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().path == dir, !name.hasPrefix("."),
              !Self.tempExtensions.contains(url.pathExtension.lowercased()),
              !seen.contains(url.path), !pending.contains(url.path) else { return }
        pending.insert(url.path)
        waitUntilStable(url, lastSize: -1, tries: 0)
    }

    /// Đợi dung lượng không đổi giữa 2 lần đọc cách 1,5 s (tối đa ~1 phút) rồi mới thêm.
    private func waitUntilStable(_ url: URL, lastSize: Int64, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isPackageKey, .creationDateKey])
                guard let values, values.isDirectory != true || values.isPackage == true else {
                    self.pending.remove(url.path); return
                }
                let size = Int64(values.fileSize ?? 0)
                if size > 0, size == lastSize {
                    self.pending.remove(url.path)
                    guard self.isFreshDownload(url, created: values.creationDate) else { return }
                    self.seen.insert(url.path)
                    self.onFile?(url)
                } else if tries < 40 {
                    self.waitUntilStable(url, lastSize: size, tries: tries + 1)
                } else {
                    self.pending.remove(url.path)
                }
            }
        }
    }

    /// File do chính Roost lưu vào Downloads (Portal): không tính là tải về.
    func markSeen(_ url: URL) { seen.insert(url.standardizedFileURL.path) }

    private func isFreshDownload(_ url: URL, created: Date?) -> Bool {
        if getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 { return true }
        return (created.map { Date().timeIntervalSince($0) < 600 }) ?? false
    }
}
