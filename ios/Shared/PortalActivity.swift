import ActivityKit
import Foundation

/// Live Activity khi gửi: tiến độ trên Dynamic Island và màn hình khoá (dùng chung app và widget).
struct PortalActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var progress: Double
        var done: Bool = false
        var failed: Bool = false
    }
    var macName: String
}
