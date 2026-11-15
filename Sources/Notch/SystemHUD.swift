import AppKit
import SwiftUI
import CoreAudio
import FaceUnlockKit

// Thay HUD âm lượng / độ sáng / đèn bàn phím của macOS: event tap nuốt phím media (NX_SYSDEFINED),
// tự chỉnh giá trị rồi hiện ở hai cánh notch. Cần quyền Trợ năng; không có quyền hoặc notch đang
// không hiện được (toàn màn hình, đang mở) thì trả phím lại cho hệ thống để HUD gốc vẫn hiện.

struct HUDPeek: Equatable {
    enum Kind: Equatable { case volume, brightness, keyboard }
    let kind: Kind
    let level: Double
    var muted = false

    var symbol: String {
        switch kind {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness: return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard: return level < 0.5 ? "light.min" : "light.max"
        }
    }
}

@MainActor
final class SystemHUD {
    static let shared = SystemHUD()

    /// Hiện HUD lên notch. Trả false nếu notch không hiện được lúc này (để hệ thống tự hiện).
    var show: ((HUDPeek) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var axObserver: NSObjectProtocol?

    private static let step = 1.0 / 16
    private static let fineStep = 1.0 / 64

    func start() {
        // Quyền Trợ năng đổi thì macOS bắn notification này: bật/tắt tap theo, không cần timer.
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { SystemHUD.shared.sync() } }
        }
        sync()
    }

    func sync() {
        if AlertSettings.shared.hud && FaceUnlockService.isAccessibilityTrusted { enable() } else { disable() }
    }

    private func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: hudTapCallback, userInfo: nil) else { return }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
    }

    private func disable() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// true = đã xử lý, nuốt phím.
    fileprivate func handle(key: Int32, down: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        // Option (không kèm Shift) + phím media = mở pane Cài đặt tương ứng: để hệ thống lo.
        if flags.contains(.option) && !flags.contains(.shift) { return false }
        let fine = flags.contains(.option) && flags.contains(.shift)
        let delta = fine ? Self.fineStep : Self.step
        switch key {
        case 0, 1, 7: return volume(key: key, down: down, delta: delta)
        case 2, 3: return brightness(up: key == 2, down: down, delta: delta)
        case 21, 22, 23: return keyboard(key: key, down: down, delta: delta)
        default: return false
        }
    }

    private func volume(key: Int32, down: Bool, delta: Double) -> Bool {
        let id = CA.defaultDevice(output: true)
        guard let current = CA.volume(id, output: true) else { return false }
        guard down else { return false }
        var level = Double(current)
        var muted = CA.muted(id, output: true)
        switch key {
        case 7:
            muted.toggle()
            CA.setMuted(id, output: true, muted)
        default:
            level = min(max(level + (key == 0 ? delta : -delta), 0), 1)
            level = (level / delta).rounded() * delta
            CA.setVolume(id, output: true, Float(level))
            if muted { CA.setMuted(id, output: true, false); muted = false }
        }
        return show?(HUDPeek(kind: .volume, level: level, muted: muted)) ?? false
    }

    private func brightness(up: Bool, down: Bool, delta: Double) -> Bool {
        guard let display = DisplayBrightness.builtin, let current = DisplayBrightness.get(display) else { return false }
        guard down else { return false }
        let level = min(max(((current + (up ? delta : -delta)) / delta).rounded() * delta, 0), 1)
        DisplayBrightness.set(display, level)
        return show?(HUDPeek(kind: .brightness, level: level)) ?? false
    }

    private func keyboard(key: Int32, down: Bool, delta: Double) -> Bool {
        guard let current = KeyboardBacklight.get() else { return false }
        guard down else { return false }
        var level: Double
        switch key {
        case 23: level = current > 0 ? 0 : 0.5
        default: level = min(max(((current + (key == 21 ? delta : -delta)) / delta).rounded() * delta, 0), 1)
        }
        KeyboardBacklight.set(level)
        return show?(HUDPeek(kind: .keyboard, level: level)) ?? false
    }
}

private func hudTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { SystemHUD.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let data = ns.data1
    let key = Int32((data & 0xFFFF0000) >> 16)
    let state = (data & 0xFF00) >> 8
    let down = state == 0xA
    // Chỉ nuốt lúc bấm. Nhả phím phải tới hệ thống, không thì bộ lặp phím của macOS lặp mãi (âm lượng tự chạy về 0/100).
    guard down else { return Unmanaged.passUnretained(event) }
    let flags = ns.modifierFlags
    let handled = MainActor.assumeIsolated { SystemHUD.shared.handle(key: key, down: down, flags: flags) }
    return handled ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Độ sáng màn hình tích hợp (DisplayServices, framework riêng)

enum DisplayBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Getter? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter: Setter? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    static var builtin: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }

    static func get(_ id: CGDirectDisplayID) -> Double? {
        guard let getter else { return nil }
        var v: Float = 0
        return getter(id, &v) == 0 ? Double(v) : nil
    }

    static func set(_ id: CGDirectDisplayID, _ value: Double) { _ = setter?(id, Float(value)) }
}

// MARK: - Đèn bàn phím (CoreBrightness KeyboardBrightnessClient, framework riêng)

enum KeyboardBacklight {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    private static var keyboardID: UInt64? {
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let client, client.responds(to: sel),
              let ids = client.perform(sel)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }

    static func get() -> Double? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let client, let id = keyboardID, client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        return Double(fn(client, sel, id))
    }

    static func set(_ value: Double) {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, let id = keyboardID, client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        _ = fn(client, sel, Float(value), id)
    }
}

// MARK: - Giao diện ở hai cánh

/// Icon bên trái, thanh mức + % bên phải (như hai ảnh mẫu).
struct HUDWings: View {
    let hud: HUDPeek
    let wing: CGFloat

    var body: some View {
        let ink: Color = Theme.isCassette ? CassettePalette.label : Theme.isVanGogh ? VG.cream : .white
        let fill: Color = Theme.isVanGogh ? VG.yellow : Theme.isPixel ? PixelPalette.border : ink
        HStack(spacing: 0) {
            Image(systemName: hud.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink.opacity(hud.muted ? 0.5 : 0.95))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, alignment: .leading)
                .padding(.leading, 12)
                .frame(width: wing, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 2).fill(ink.opacity(0.22))
                        RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 2).fill(fill.opacity(hud.muted ? 0.35 : 1))
                            .frame(width: g.size.width * (hud.muted ? 0 : hud.level))
                    }
                }
                .frame(width: 22, height: 4)
                Text(hud.muted ? L("Tắt", "Off") : "\(Int((hud.level * 100).rounded()))%")
                    .font(.ui(11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.trailing, 8)
            .frame(width: wing, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.15), value: hud)
    }
}
