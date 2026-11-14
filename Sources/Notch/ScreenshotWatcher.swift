import AppKit
import ImageIO

/// Ảnh chụp màn hình mới → báo ra ngoài. Hai đường:
/// - lưu ra file: Spotlight gắn cờ kMDItemIsScreenCapture (thư mục nào cũng được, không cần quyền);
/// - chụp vào clipboard (⌃⌘⇧4, hoặc target = clipboard): clipboard chỉ có ảnh *và* UI chụp màn hình
///   của macOS vừa chạy → lưu PNG vào Application Support/Roost/Screenshots rồi đưa vào khay.
///   (Chỉ xét "clipboard chỉ có ảnh" thì copy ảnh trong Preview… cũng bị nhận nhầm.)
@MainActor
final class ScreenshotWatcher {
    var onNew: ((URL, NSImage?) -> Void)?
    private var query: NSMetadataQuery?
    private var running = false
    private var seen = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private var clipboardTimer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    /// File khay đang giữ: không dọn ảnh clipboard còn nằm trong khay.
    var keep: () -> [URL] = { [] }

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Roost/Screenshots", isDirectory: true)

    /// Lần cuối thấy UI chụp màn hình (screencaptureui) mở / tắt.
    private var captureSeenAt = Date.distantPast
    nonisolated private static let captureBundle = "com.apple.screencaptureui"
    private var appsObservation: NSKeyValueObservation?

    /// Chỉ chạy khi bật "Ảnh chụp vào khay": tắt thì không đọc clipboard, không giữ truy vấn Spotlight.
    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        running = true
        cleanup()
        changeCount = NSPasteboard.general.changeCount
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.captureBundle else { return }
                MainActor.assumeIsolated { self?.captureSeenAt = Date() }
            })
        }
        // KVO bắt cả app nền (thông báo launch/terminate có thể bỏ sót app không có Dock icon).
        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            let apps = (change.newValue ?? []) + (change.oldValue ?? [])
            guard apps.contains(where: { $0.bundleIdentifier == Self.captureBundle }) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.captureSeenAt = Date() } }
        }
        // changeCount là số nguyên, đọc rẻ; 2 lần/giây.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        timer.tolerance = 0.2
        clipboardTimer = timer
        let since = Date() as NSDate
        let query = NSMetadataQuery()
        self.query = query
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", since)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            })
        }
        query.start()
    }

    private func stop() {
        guard running else { return }
        running = false
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        appsObservation = nil
        query?.stop()
        query = nil
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
    }

    private func collect() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  seen.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path)
            else { continue }
            let url = URL(fileURLWithPath: path)
            onNew?(url, Self.thumbnail(url))
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        let types = Set(pb.types ?? [])
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        // Ảnh chụp vào clipboard chỉ có dữ liệu ảnh; copy ảnh từ web/app thường kèm html, text, url, file.
        let extras: [NSPasteboard.PasteboardType] = [.html, .string, .fileURL, .URL, .rtf,
                                                     .init("org.chromium.source-url")]
        guard imageTypes.contains(where: types.contains), !extras.contains(where: types.contains),
              screenCaptureActive(),
              let data = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap(Self.png)
        else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.folder.appendingPathComponent(L("Ảnh chụp ", "Screenshot ") + formatter.string(from: Date()) + ".png")
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch { return }
        onNew?(url, Self.thumbnail(url))
    }

    /// UI chụp màn hình đang chạy, hoặc vừa mở / tắt trong vài giây (đọc clipboard 2 lần/giây nên
    /// lúc kiểm tra nó có thể đã thoát). Tiến trình `screencapture` (dòng lệnh, ⌃⌘⇧3) không có trong
    /// NSWorkspace → quét tên tiến trình, chỉ khi clipboard vừa đổi sang ảnh.
    private func screenCaptureActive() -> Bool {
        if Date().timeIntervalSince(captureSeenAt) < 4 { return true }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.captureBundle).isEmpty { return true }
        return Self.processRunning(["screencaptureui", "screencapture"])
    }

    private static func processRunning(_ names: Set<String>) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        for i in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            var comm = procs[i].kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if names.contains(name) { return true }
        }
        return false
    }

    private static func png(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// Ảnh clipboard cũ hơn 3 ngày và không còn trong khay thì xoá.
    private func cleanup() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let kept = Set(keep().map(\.standardizedFileURL.path))
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        for url in files where !kept.contains(url.standardizedFileURL.path) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 120,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
