import AppKit
import UniformTypeIdentifiers

/// Khay giữ tham chiếu tới file gốc (không chép), lưu qua UserDefaults để còn sau khi mở lại app.
@MainActor
final class TrayStore: ObservableObject {
    @Published private(set) var files: [URL] = []

    private let key = "trayFiles"

    init() {
        files = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
        prune()
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
        guard !files.contains(url) else { return }
        files.append(url)
        save()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    /// Bỏ file đã bị xoá/di chuyển khỏi chỗ cũ.
    func prune() {
        let alive = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        if alive != files { files = alive; save() }
    }

    private func save() {
        UserDefaults.standard.set(files.map(\.path), forKey: key)
    }
}
