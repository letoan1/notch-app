import Foundation

/// Chuyển dữ liệu từ bản cũ tên "Notch" (bundle id local.toan.notch) sang Roost, một lần, chạy trước mọi thứ khác.
/// Không xoá dữ liệu cũ: UserDefaults chỉ chép; thư mục Application Support được dời (rename, cùng ổ đĩa)
/// hoặc gộp không ghi đè nếu Roost/ đã có.
enum RoostMigration {
    static let oldDomain = "local.toan.notch"
    static let flag = "migratedFromNotch"

    static func run() {
        migrateDefaults()
        migrateSupportFolder()
    }

    private static func migrateDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: flag) else { return }
        if let old = d.persistentDomain(forName: oldDomain) {
            for (key, value) in old where !key.hasPrefix("NSWindow Frame") {
                // Không đè giá trị Roost đã có (chạy lại sau khi lỡ tạo key mới).
                if d.object(forKey: key) == nil { d.set(value, forKey: key) }
            }
        }
        d.set(true, forKey: flag)
    }

    private static func migrateSupportFolder() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Notch", isDirectory: true)
        let new = base.appendingPathComponent("Roost", isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: new.path) {
            if (try? fm.moveItem(at: old, to: new)) != nil { return }
        }
        merge(old, into: new)
    }

    /// Dời từng mục chưa có ở đích; thư mục trùng thì gộp đệ quy; file trùng thì giữ cả hai (không ghi đè).
    private static func merge(_ src: URL, into dst: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: item, to: target)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                merge(item, into: target)
            }
        }
    }
}
