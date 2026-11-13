import AppKit

/// Rung nhẹ trên trackpad Force Touch (MacBook, Magic Trackpad 2). Chỉ cảm nhận được khi
/// ngón tay đang đặt trên trackpad; chuột thường thì không có gì xảy ra.
@MainActor
enum Haptics {
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard SettingsStore.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
