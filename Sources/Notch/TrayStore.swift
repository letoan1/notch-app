import AppKit
import Combine
import UniformTypeIdentifiers

/// Khay giữ bookmark tới file gốc (không chép): file bị di chuyển / đổi tên vẫn theo được.
/// Tự bỏ file đã xoá (kể cả vào Thùng rác) và file quá hạn theo Cài đặt "Tự dọn khay".
@MainActor
final class TrayStore: ObservableObject {
    struct Item: Codable {
        var bookmark: Data
        var addedAt: Date
        var path: String
    }

    /// URL hiện tại của từng file, cùng thứ tự với `items`.
    @Published private(set) var files: [URL] = []

    private var items: [Item] = []
    private let key = "trayItems"
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        load()
        prune()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        SettingsStore.shared.$trayExpiryDays.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }.store(in: &cancellables)
    }

    func accept(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.add(url) }
                }
            }
        }
    }

    func add(_ url: URL) {
        let url = url.standardizedFileURL
        guard !files.contains(url), let item = Self.makeItem(url, addedAt: Date()) else { return }
        items.append(item)
        files.append(url)
        save()
    }

    func remove(_ url: URL) {
        guard let index = files.firstIndex(of: url) else { return }
        files.remove(at: index)
        items.remove(at: index)
        save()
    }

    func clear() {
        items.removeAll()
        files.removeAll()
        save()
    }

    /// Resolve lại bookmark (cập nhật đường dẫn mới), bỏ file đã xoá / quá hạn.
    func prune() {
        let maxDays = SettingsStore.shared.trayExpiryDays
        let now = Date()
        var keptItems: [Item] = []
        var keptURLs: [URL] = []
        for var item in items {
            if maxDays > 0, now.timeIntervalSince(item.addedAt) > Double(maxDays) * 86_400 { continue }
            guard let url = Self.resolve(&item), !keptURLs.contains(url) else { continue }
            keptItems.append(item)
            keptURLs.append(url)
        }
        items = keptItems
        if files != keptURLs { files = keptURLs }
        save()
    }

    // MARK: - Lưu trữ

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else if let legacy = defaults.stringArray(forKey: "trayFiles") {
            // Bản cũ lưu đường dẫn → chuyển sang bookmark một lần.
            items = legacy.compactMap { Self.makeItem(URL(fileURLWithPath: $0), addedAt: Date()) }
            defaults.removeObject(forKey: "trayFiles")
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func makeItem(_ url: URL, addedAt: Date) -> Item? {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        return Item(bookmark: bookmark, addedAt: addedAt, path: url.path)
    }

    /// URL hiện tại của file; nil nếu đã xoá hoặc nằm trong Thùng rác.
    private static func resolve(_ item: inout Item) -> URL? {
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: item.bookmark,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        let url = resolved.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path), !url.path.contains("/.Trash/") else { return nil }
        // File đã đổi chỗ / tên: làm mới bookmark + đường dẫn, giữ nguyên thời điểm thêm vào khay.
        if stale || url.path != item.path, let fresh = makeItem(url, addedAt: item.addedAt) {
            item = fresh
        }
        return url
    }
}
