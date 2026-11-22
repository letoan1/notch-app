import AppKit

/// Thẻ từ lệnh `roost push` (script, cron, n8n… trên cùng máy), nhận qua socket của roost-hook.
/// Chỉ tiến trình của chính người dùng ghi được vào socket (thư mục 0700), không có webhook qua mạng.
@MainActor
enum PushAlerts {
    static func handle(_ obj: [String: Any]) {
        guard AlertSettings.shared.push else { return }
        let id = (obj["id"] as? String).map { String($0.prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
        if obj["clear"] as? Bool == true {
            if let id { AlertCenter.shared.dismiss(key: "push:" + id) }
            return
        }
        let title = String((obj["title"] as? String ?? "").prefix(120))
        guard !title.isEmpty else { return }
        let body = String((obj["body"] as? String ?? "").prefix(300))
        let progress = (obj["progress"] as? Double).map { min(max($0, 0), 100) }
        let done = progress == 100
        let tone: NotchAlert.Tone = switch obj["tone"] as? String ?? "" {
            case "red": .red
            case "green": .green
            case "yellow": .yellow
            case "blue": .blue
            default: done ? .green : .blue
        }
        let symbol = (obj["icon"] as? String).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
            ?? (done ? "checkmark.circle.fill" : progress != nil ? "arrow.triangle.2.circlepath" : "bell.fill")
        // Đang chạy: giữ thẻ lâu để lần cập nhật sau nối tiếp. 0 = tới khi --clear (tối đa 1 giờ).
        let duration: TimeInterval = (obj["duration"] as? Double).map { $0 <= 0 ? 3600 : min($0, 3600) }
            ?? (progress != nil && !done ? 30 : 6)
        let url = (obj["open"] as? String).flatMap { URL(string: $0) }.flatMap { $0.scheme == nil ? nil : $0 }
        AlertCenter.shared.post(NotchAlert(
            kind: .push, title: title,
            highlight: progress.map { "\(Int($0.rounded()))%" },
            subtitle: body,
            icon: .symbol(symbol), tone: tone,
            priority: obj["urgent"] as? Bool == true ? 2 : 1,
            duration: duration, action: url.map { .open($0) } ?? .none,
            pushID: id, progress: progress.map { $0 / 100 }))
    }
}
