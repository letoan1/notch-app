import AppKit
import ImageIO

/// Ảnh chụp màn hình mới → báo ra ngoài. Hai đường:
/// - lưu ra file: Spotlight gắn cờ kMDItemIsScreenCapture (thư mục nào cũng được, không cần quyền);
/// - chụp vào clipboard (⌃⌘⇧4, hoặc target = clipboard): clipboard chỉ có ảnh → lưu PNG vào
///   Application Support/Notch/Screenshots rồi đưa vào khay.
@MainActor
final class ScreenshotWatcher {
    var onNew: ((URL, NSImage?) -> Void)?
    private let query = NSMetadataQuery()
    private var seen = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private var clipboardTimer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    /// File khay đang giữ: không dọn ảnh clipboard còn nằm trong khay.
    var keep: () -> [URL] = { [] }

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Notch/Screenshots", isDirectory: true)

    func start() {
        cleanup()
        // changeCount là số nguyên, đọc rẻ; 2 lần/giây.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        timer.tolerance = 0.2
        clipboardTimer = timer
        let since = Date() as NSDate
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", since)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            })
        }
        query.start()
    }

    private func collect() {
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
