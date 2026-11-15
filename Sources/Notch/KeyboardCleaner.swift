import AppKit
import FaceUnlockKit

// Chế độ lau phím: event tap nuốt mọi lần bấm phím (cả phím media, độ sáng) để lau bàn phím.
// Mở: bấm thẻ trên notch / bấm lại nút, Esc 5 lần, hoặc tự mở sau 3 phút. Nhả phím và phím bổ trợ
// vẫn cho qua: nuốt nhả phím làm bộ lặp phím của macOS kẹt (xem SystemHUD).

@MainActor
final class KeyboardCleaner: ObservableObject {
    static let shared = KeyboardCleaner()
    static let autoUnlock: TimeInterval = 180

    @Published private(set) var locked = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var escCount = 0
    private var lastEsc = Date.distantPast
    private var endsAt = Date()

    func toggle() { locked ? unlock() : lock() }

    func lock() {
        guard !locked else { return }
        guard FaceUnlockService.isAccessibilityTrusted else {
            _ = FaceUnlockService.promptForAccessibility()
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << 14)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cleanerTapCallback, userInfo: nil) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        locked = true
        escCount = 0
        endsAt = Date().addingTimeInterval(Self.autoUnlock)
        timer = Timer.scheduledTimer(withTimeInterval: Self.autoUnlock, repeats: false) { _ in
            MainActor.assumeIsolated { KeyboardCleaner.shared.unlock() }
        }
        timer?.tolerance = 1
        postCard()
    }

    func unlock() {
        guard locked else { return }
        timer?.invalidate()
        timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        locked = false
        AlertCenter.shared.dismiss(.keyboardLock)
    }

    /// Notch vừa thu lại: thẻ đã nhường chỗ lúc notch mở, hiện lại nếu vẫn đang khoá.
    func repostIfLocked() { if locked { postCard() } }

    private func postCard() {
        AlertCenter.shared.post(NotchAlert(
            kind: .keyboardLock, title: L("Đang lau bàn phím", "Cleaning the keyboard"), highlight: nil,
            subtitle: L("Bấm vào đây hoặc Esc 5 lần để mở. Tự mở sau 3 phút.",
                        "Click here or press Esc 5 times to unlock. Unlocks by itself after 3 minutes."),
            icon: .symbol("keyboard"), tone: .blue, priority: 2,
            duration: max(endsAt.timeIntervalSinceNow, 1), action: .unlockKeyboard))
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    fileprivate func escPressed() {
        let now = Date()
        escCount = now.timeIntervalSince(lastEsc) < 2 ? escCount + 1 : 1
        lastEsc = now
        if escCount >= 5 { unlock() }
    }
}

private func cleanerTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { KeyboardCleaner.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !repeated, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            MainActor.assumeIsolated { KeyboardCleaner.shared.escPressed() }
        }
        return nil
    }
    // Phím media / độ sáng: chỉ nuốt lúc bấm, nhả thì cho qua.
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        return (ns.data1 & 0xFF00) >> 8 == 0xA ? nil : Unmanaged.passUnretained(event)
    }
    return Unmanaged.passUnretained(event)
}
