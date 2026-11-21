import AppKit
import SwiftUI

// MARK: - Cài đặt "Thông báo trên notch"

/// Cài đặt riêng cho các thông báo hệ thống và Giữ máy thức (tách khỏi SettingsStore cho gọn).
@MainActor
final class AlertSettings: ObservableObject {
    static let shared = AlertSettings()

    @Published var battery: Bool { didSet { save(battery, "alerts.battery") } }
    @Published var capsLock: Bool { didSet { save(capsLock, "alerts.capsLock") } }
    /// Đổi bộ gõ tiếng Việt / tiếng Anh của macOS: hiện V hoặc E.
    @Published var inputSource: Bool { didSet { save(inputSource, "alerts.inputSource") } }
    @Published var network: Bool { didSet { save(network, "alerts.network") } }
    @Published var downloadsToTray: Bool { didSet { save(downloadsToTray, "alerts.downloadsToTray") } }
    /// Thay HUD âm lượng / độ sáng / đèn bàn phím của macOS (cần quyền Trợ năng).
    @Published var hud: Bool { didSet { save(hud, "alerts.hud"); SystemHUD.shared.sync() } }
    /// Giờ hết làm, tính bằng phút từ 0:00 (mặc định 18:00).
    @Published var workEndMinutes: Int { didSet { save(workEndMinutes, "awake.workEnd") } }
    @Published var awakeStopOnLowBattery: Bool { didSet { save(awakeStopOnLowBattery, "awake.stopLowBattery") } }
    @Published var awakeStopOnLid: Bool { didSet { save(awakeStopOnLid, "awake.stopLid") } }
    /// Gập máy mà có màn rời: vẫn giữ thức (kể cả chạy pin).
    @Published var awakeClosedLid: Bool { didSet { save(awakeClosedLid, "awake.closedLid"); KeepAwake.shared.syncClosedLid() } }

    private init() {
        let d = UserDefaults.standard
        battery = d.object(forKey: "alerts.battery") as? Bool ?? true
        capsLock = d.object(forKey: "alerts.capsLock") as? Bool ?? true
        inputSource = d.object(forKey: "alerts.inputSource") as? Bool ?? true
        network = d.object(forKey: "alerts.network") as? Bool ?? true
        downloadsToTray = d.object(forKey: "alerts.downloadsToTray") as? Bool ?? true
        hud = d.object(forKey: "alerts.hud") as? Bool ?? true
        workEndMinutes = d.object(forKey: "awake.workEnd") as? Int ?? 18 * 60
        awakeStopOnLowBattery = d.object(forKey: "awake.stopLowBattery") as? Bool ?? true
        awakeStopOnLid = d.object(forKey: "awake.stopLid") as? Bool ?? true
        awakeClosedLid = d.object(forKey: "awake.closedLid") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    /// Mốc giờ hết làm hôm nay (nil nếu đã qua).
    var workEndToday: Date? {
        let cal = Calendar.current
        guard let end = cal.date(bySettingHour: workEndMinutes / 60, minute: workEndMinutes % 60, second: 0, of: Date()),
              end > Date() else { return nil }
        return end
    }

    var workEndText: String { String(format: "%d:%02d", workEndMinutes / 60, workEndMinutes % 60) }
}

// MARK: - Thông báo dạng thẻ

/// Thẻ thông báo: notch thả xuống thành một thẻ rộng có icon, tiêu đề đậm và 1-2 dòng mô tả.
struct NotchAlert: Equatable, Identifiable {
    enum Kind: String { case lowBattery, batteryFull, networkLost, networkBack, awakeEnding, awakeOff, device, keyboardLock, permissionLost, moneyReceived }
    enum Tone { case red, green, yellow, blue, neutral }
    enum Icon: Equatable {
        case battery(Double)
        case symbol(String)
    }
    enum Action { case none, batterySettings, networkSettings, extendAwake, unlockKeyboard, grantPermission }

    let id = UUID()
    let kind: Kind
    var title: String
    /// Phần tô màu theo tone ngay sau tiêu đề (ví dụ "10%").
    var highlight: String?
    var subtitle: String
    var icon: Icon
    var tone: Tone
    /// 2 = quan trọng (hiện cả khi toàn màn hình), 1 = thường, 0 = thông tin.
    var priority: Int
    var duration: TimeInterval
    var action: Action
    /// Thẻ thiết bị: % pin vẽ thành vòng bên phải (nil = không đọc được).
    var ring: Int? = nil

    static func == (a: NotchAlert, b: NotchAlert) -> Bool { a.id == b.id }

    static let cardHeight: CGFloat = 62
    /// Thẻ thiết bị chỉ có một dòng tên + vòng pin nhỏ: thấp hơn.
    var height: CGFloat { kind == .device ? 46 : Self.cardHeight }
    static let cardWidth: CGFloat = 420
}

/// Hàng đợi thẻ thông báo: mỗi lúc một thẻ, thẻ quan trọng chen lên trước, cùng loại thì thay thế.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    /// Đặt thẻ lên các notch (nil = gỡ). Trả false nếu chưa hiện được (notch đang mở).
    var apply: ((NotchAlert?) -> Bool)?
    private(set) var current: NotchAlert?
    private var queue: [NotchAlert] = []
    private var timer: Timer?
    private var hovering = false

    func post(_ alert: NotchAlert) {
        queue.removeAll { $0.kind == alert.kind }
        if let c = current {
            if c.kind == alert.kind || alert.priority > c.priority {
                if c.kind != alert.kind { queue.insert(c, at: 0) }
                show(alert)
            } else {
                queue.append(alert)
                queue.sort { $0.priority > $1.priority }
            }
        } else {
            show(alert)
        }
    }

    /// Gỡ thẻ của một loại (đang hiện hoặc đang chờ), ví dụ có mạng lại thì bỏ thẻ mất mạng.
    func dismiss(_ kind: NotchAlert.Kind) {
        queue.removeAll { $0.kind == kind }
        if current?.kind == kind { finish() }
    }

    /// Chuột trên thẻ: giữ thẻ mở.
    func setHovering(_ value: Bool) { hovering = value }

    /// Bấm vào thẻ: chạy hành động rồi đóng.
    func activate() {
        guard let alert = current else { return }
        switch alert.action {
        case .none: break
        case .batterySettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .networkSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
        case .extendAwake:
            KeepAwake.shared.extend(minutes: 15)
        case .unlockKeyboard:
            KeyboardCleaner.shared.unlock()
        case .grantPermission:
            PermissionWatch.shared.grantFirstMissing()
        }
        hovering = false
        finish()
    }

    /// Notch vừa mở: thẻ đang hiện nhường chỗ (bỏ luôn, không hiện lại).
    func notchExpanded() {
        timer?.invalidate()
        current = nil
    }

    /// Notch vừa thu lại: hiện thẻ đang chờ.
    func notchCollapsed() {
        KeyboardCleaner.shared.repostIfLocked()
        guard current == nil, !queue.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.next() }
        }
    }

    private func show(_ alert: NotchAlert) {
        current = alert
        guard apply?(alert) == true else {
            current = nil
            queue.insert(alert, at: 0)
            return
        }
        schedule(alert.duration)
    }

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovering { self.schedule(1) } else { self.finish() }
            }
        }
        timer?.tolerance = 0.2
    }

    private func finish() {
        timer?.invalidate()
        current = nil
        _ = apply?(nil)
        guard !queue.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated { self?.next() }
        }
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        show(queue.removeFirst())
    }
}

// MARK: - Giao diện thẻ

/// Thẻ thông báo vẽ theo từng giao diện. Nằm dưới phần notch thật (camera) để chữ không bị che.
struct AlertCard: View {
    let alert: NotchAlert
    let notchHeight: CGFloat

    var body: some View {
        if alert.kind == .device { deviceBody } else { standardBody }
    }

    /// Thiết bị vừa kết nối: icon trái, "Đã kết nối" + tên ở giữa, vòng pin phải.
    private var deviceBody: some View {
        HStack(spacing: 0) {
            Group {
                if case let .symbol(name) = alert.icon {
                    Image(systemName: name).font(.system(size: 24, weight: .regular)).foregroundStyle(ink)
                }
            }
            .frame(width: 36, height: 36)
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                Text(alert.subtitle).font(.ui(11.5, weight: .semibold)).foregroundStyle(ink.opacity(0.55))
                Text(alert.title).font(titleFont).foregroundStyle(ink).lineLimit(1)
            }
            Spacer(minLength: 8)
            Group {
                if let level = alert.ring { DeviceBatteryRing(level: level, ink: ink) }
            }
            .frame(width: 36, height: 36)
        }
        .padding(.horizontal, 24)
        .padding(.top, notchHeight + 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if Theme.isVanGogh { VGPanelBackground().overlay(VG.night.opacity(0.55)) }
        }
        .clipped()
    }

    private var standardBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AlertIcon(icon: alert.icon, tone: alert.tone)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    (Text(alert.title) + Text(alert.highlight.map { " " + $0 } ?? "").foregroundColor(Self.color(alert.tone)))
                        .font(titleFont)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Text(alert.subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(ink.opacity(Theme.isCassette ? 0.75 : 0.62))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if alert.action != .none {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ink.opacity(0.35))
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, notchHeight + 6)
            .padding(.bottom, 10)
            .background(alignment: .bottom) {
                if Theme.isCassette {
                    // Tờ giấy dán: mép dưới hơi lệch như nhãn băng.
                    Rectangle().fill(CassettePalette.marker.opacity(0.85)).frame(height: 3)
                        .padding(.horizontal, 30).offset(y: -4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Van Gogh: nền tranh nằm sau, không làm giãn bố cục.
        .background {
            if Theme.isVanGogh {
                VGPanelBackground().overlay(VG.night.opacity(0.55))
            }
        }
        .clipped()
    }

    private var ink: Color {
        switch Theme.current {
        case .cassette: return CassettePalette.label
        case .pixel: return PixelPalette.border
        case .vangogh: return VG.cream
        case .standard: return .white
        }
    }
    private var titleFont: Font {
        switch Theme.current {
        case .cassette: return .hand(17)
        case .pixel: return .ui(13)
        default: return .ui(14, weight: .bold)
        }
    }
    private var subtitleFont: Font {
        switch Theme.current {
        case .cassette: return .typewriter(11)
        case .pixel: return .ui(10)
        case .vangogh: return .ui(12).italic()
        case .standard: return .ui(12)
        }
    }

    static func color(_ tone: NotchAlert.Tone) -> Color {
        switch tone {
        case .red: return Color(red: 1, green: 0.27, blue: 0.27)
        case .green: return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .yellow: return Theme.isVanGogh ? VG.yellow : Color(red: 1, green: 0.78, blue: 0.25)
        case .blue: return Color(red: 0.4, green: 0.7, blue: 1)
        case .neutral: return .white.opacity(0.8)
        }
    }
}

/// Vòng pin thiết bị: xanh, dưới 20% thì đỏ, số % ở giữa.
private struct DeviceBatteryRing: View {
    let level: Int
    let ink: Color

    var body: some View {
        let color = AlertCard.color(level <= 20 ? .red : .green)
        ZStack {
            Circle().stroke(ink.opacity(0.15), lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(min(max(level, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: Theme.isPixel ? .butt : .round))
                .rotationEffect(.degrees(-90))
            Text("\(level)").font(.ui(11, weight: .bold).monospacedDigit()).foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
    }
}

private struct AlertIcon: View {
    let icon: NotchAlert.Icon
    let tone: NotchAlert.Tone

    var body: some View {
        let color = AlertCard.color(tone)
        ZStack {
            if Theme.isPixel {
                Rectangle().fill(color.opacity(0.18))
                Rectangle().strokeBorder(color.opacity(0.8), lineWidth: 2)
            } else if Theme.isCassette {
                RoundedRectangle(cornerRadius: 4).fill(CassettePalette.shell)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(CassettePalette.shellEdge, lineWidth: 1))
            } else {
                Circle().fill(color.opacity(0.16))
            }
            switch icon {
            case let .battery(level):
                AlertBatteryGlyph(level: level, color: color).frame(width: 26, height: 13)
            case let .symbol(name):
                Image(systemName: name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
    }
}

/// Pin vẽ tay: viền mờ, ruột theo mức pin.
struct AlertBatteryGlyph: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 3, h = geo.size.height
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 3).stroke(color.opacity(0.55), lineWidth: 1.4)
                    RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 1.6).fill(color)
                        .frame(width: max(2, (w - 4) * level), height: h - 4)
                        .padding(.leading, 2)
                }
                .frame(width: w, height: h)
                RoundedRectangle(cornerRadius: 0.6).fill(color.opacity(0.55)).frame(width: 2, height: h * 0.4)
            }
        }
    }
}

// MARK: - Caps Lock (thông báo nhỏ ở 2 cánh)

struct CapsLockWings: View {
    let on: Bool
    let wing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: on ? "capslock.fill" : "capslock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? AlertCard.color(.green) : ink.opacity(0.6))
                .frame(width: wing)
            Spacer(minLength: 0)
            Text(on ? "ON" : "OFF")
                .font(Theme.isCassette ? .hand(14) : .ui(12, weight: .bold))
                .foregroundStyle(on ? AlertCard.color(.green) : ink.opacity(0.6))
                .frame(width: wing)
        }
    }

    private var ink: Color {
        Theme.isCassette ? CassettePalette.label : Theme.isVanGogh ? VG.cream : .white
    }
}

/// Đổi bộ gõ: bàn phím bên trái, chữ V (tiếng Việt) hoặc E (tiếng Anh) bên phải.
struct InputSourceWings: View {
    let vietnamese: Bool
    let wing: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: wing)
            Spacer(minLength: 0)
            Text(vietnamese ? "V" : "E")
                .font(Theme.isCassette ? .hand(16) : .ui(14, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: wing)
        }
    }

    private var tint: Color { vietnamese ? AlertCard.color(.green) : ink.opacity(0.75) }

    private var ink: Color {
        Theme.isCassette ? CassettePalette.label : Theme.isVanGogh ? VG.cream : .white
    }
}
