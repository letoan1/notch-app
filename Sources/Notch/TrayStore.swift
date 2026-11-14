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
    @Published private(set) var files: [URL] = [] {
        didSet {
            let keep = Set(files)
            if !selection.isSubset(of: keep) { selection.formIntersection(keep) }
            if filter != .all, !files.contains(where: { Kind(url: $0) == filter.kind }) { filter = .all }
        }
    }

    /// Nhóm file cho bộ lọc nhỏ trên khay.
    enum Kind: Equatable {
        case image, document, other

        init(url: URL) {
            guard !url.hasDirectoryPath, let type = UTType(filenameExtension: url.pathExtension) else {
                self = .other
                return
            }
            if type.conforms(to: .image) || type.conforms(to: .movie) {
                self = .image
            } else if [UTType.pdf, .text, .rtf, .presentation, .spreadsheet, .compositeContent, .epub, .json]
                        .contains(where: type.conforms(to:)) {
                self = .document
            } else {
                self = .other
            }
        }
    }

    enum Filter: CaseIterable {
        case all, images, documents, other
        var kind: Kind? {
            switch self {
            case .all: return nil
            case .images: return .image
            case .documents: return .document
            case .other: return .other
            }
        }
        var title: String {
            switch self {
            case .all: return L("Tất cả", "All")
            case .images: return L("Ảnh", "Images")
            case .documents: return L("Tài liệu", "Docs")
            case .other: return L("Khác", "Other")
            }
        }
    }

    /// Không lưu: chỉ là trạng thái giao diện.
    @Published var selection: Set<URL> = []
    @Published var filter: Filter = .all

    /// File đang hiện theo bộ lọc.
    var visibleFiles: [URL] {
        guard let kind = filter.kind else { return files }
        return files.filter { Kind(url: $0) == kind }
    }

    /// Số file mỗi nhóm (chỉ nhóm có file); 1 nhóm duy nhất thì không cần bộ lọc.
    var filterCounts: [(Filter, Int)] {
        let kinds = files.map(Kind.init(url:))
        let groups: [(Filter, Int)] = Filter.allCases.dropFirst().map { f in (f, kinds.filter { $0 == f.kind }.count) }
        let present = groups.filter { $0.1 > 0 }
        return present.count > 1 ? [(.all, files.count)] + present : []
    }

    /// Các file kéo / xem nhanh khi thao tác trên `url`: cả vùng chọn nếu `url` nằm trong đó.
    func targets(for url: URL) -> [URL] {
        selection.contains(url) ? visibleFiles.filter(selection.contains) : [url]
    }

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

    /// Thả file lên notch (toạ độ màn hình) → NotchController chạy hiệu ứng bay vào rồi mới thêm vào khay.
    var onDrop: (([URL], NSPoint) -> Void)?

    func accept(_ providers: [NSItemProvider], at point: NSPoint? = nil) {
        let group = DispatchGroup()
        let loaded = DroppedURLs()
        for (i, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { loaded.append(i, url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Giữ đúng thứ tự thả; bỏ file đã có trong khay.
                let urls = loaded.sorted.map(\.standardizedFileURL)
                let fresh = urls.filter { !self.files.contains($0) }
                if let point, let onDrop = self.onDrop, !fresh.isEmpty {
                    onDrop(fresh, point)
                } else {
                    fresh.forEach(self.add)
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
    /// Đường dẫn → lần đầu không thấy file (chỉ trong bộ nhớ).
    private var missing: [String: Date] = [:]

    func prune() {
        let maxDays = SettingsStore.shared.trayExpiryDays
        let now = Date()
        var keptItems: [Item] = []
        var keptURLs: [URL] = []
        for var item in items {
            if maxDays > 0, now.timeIntervalSince(item.addedAt) > Double(maxDays) * 86_400 { continue }
            switch Self.resolve(&item) {
            case .ok(let url):
                missing[item.path] = nil
                guard !keptURLs.contains(url) else { continue }
                keptItems.append(item)
                keptURLs.append(url)
            case .trashed:
                continue
            case .missing:
                // Lỗi có thể chỉ thoáng qua (ổ ngoài chưa gắn, iCloud đang tải, file đang ghi):
                // chỉ gỡ khi vẫn không thấy sau ít nhất 10 phút.
                if let first = missing[item.path] {
                    if now.timeIntervalSince(first) >= 600 { missing[item.path] = nil; continue }
                } else {
                    missing[item.path] = now
                }
                let url = URL(fileURLWithPath: item.path)
                guard !keptURLs.contains(url) else { continue }
                keptItems.append(item)
                keptURLs.append(url)
            }
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
    private enum Resolution { case ok(URL), trashed, missing }

    /// Đường dẫn cũ còn file → dùng tạm dù bookmark lỗi; file ở ổ chưa gắn → coi như còn (không gỡ).
    private static func fallback(_ item: Item) -> Resolution {
        let fm = FileManager.default
        if fm.fileExists(atPath: item.path) { return .ok(URL(fileURLWithPath: item.path)) }
        let parts = item.path.split(separator: "/")
        if parts.first == "Volumes", parts.count > 1, !fm.fileExists(atPath: "/Volumes/\(parts[1])") {
            return .ok(URL(fileURLWithPath: item.path))
        }
        return .missing
    }

    private static func resolve(_ item: inout Item) -> Resolution {
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: item.bookmark,
                                      options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return fallback(item) }
        let url = resolved.standardizedFileURL
        if url.path.contains("/.Trash/") { return .trashed }
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback(item) }
        // File đã đổi chỗ / tên: làm mới bookmark + đường dẫn, giữ nguyên thời điểm thêm vào khay.
        if stale || url.path != item.path, let fresh = makeItem(url, addedAt: item.addedAt) {
            item = fresh
        }
        return .ok(url)
    }
}

/// Gom URL từ các NSItemProvider (callback trên nhiều thread).
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, URL)] = []
    func append(_ i: Int, _ url: URL) { lock.lock(); items.append((i, url)); lock.unlock() }
    var sorted: [URL] { lock.lock(); defer { lock.unlock() }; return items.sorted { $0.0 < $1.0 }.map(\.1) }
}
