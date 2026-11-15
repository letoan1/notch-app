import AppKit
import IOKit
import IOKit.pwr_mgt
import SwiftUI

/// Giữ Mac và màn hình thức (kiểu Amphetamine) bằng IOPMAssertion. Hết giờ dùng timer một lần,
/// không poll. Tự tắt khi pin còn 10% (không cắm sạc), khi gập máy, hoặc khi app được chọn thoát.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    enum Mode: Equatable {
        case timed, indefinite, workEnd
        case app(pid: pid_t, name: String)
    }

    @Published private(set) var mode: Mode?
    @Published private(set) var endsAt: Date?
    var active: Bool { mode != nil }

    private var assertion: IOPMAssertionID = 0
    private var endTimer: Timer?
    private var warnTimer: Timer?
    private var observers: [Any] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, case let .app(watched, name)? = self.mode, watched == pid else { return }
                self.stop(reason: L("\(name) đã thoát.", "\(name) quit."))
            }
        })
        // Gập máy: màn hình trong biến mất (có màn rời) hoặc máy sắp ngủ.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLid(); self?.syncClosedLid() }
        })
        // Lần trước app chết khi đang chặn ngủ: trả lại ngay.
        ClosedLidMode.resetIfLeftOn()
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLid() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release(); ClosedLidMode.apply(false, wait: true) }
        })
    }

    /// Pin thay đổi (gọi từ SystemMonitor qua controller).
    func batteryChanged(percent: Int?, onAC: Bool) {
        guard active, AlertSettings.shared.awakeStopOnLowBattery, let percent, !onAC, percent <= 10 else { return }
        stop(reason: L("Pin còn \(percent)%, máy được phép ngủ để giữ pin.", "Battery at \(percent)%, your Mac can sleep again."))
    }

    func keep(minutes: Int) { begin(.timed, until: Date().addingTimeInterval(TimeInterval(minutes * 60))) }
    func keepIndefinitely() { begin(.indefinite, until: nil) }
    func keepUntilWorkEnd() {
        guard let end = AlertSettings.shared.workEndToday else { return }
        begin(.workEnd, until: end)
    }
    func keep(until app: NSRunningApplication) {
        begin(.app(pid: app.processIdentifier, name: app.localizedName ?? "App"), until: nil)
    }

    func extend(minutes: Int) {
        guard active else { keep(minutes: minutes); return }
        let base = max(endsAt ?? Date(), Date())
        begin(mode == .workEnd ? .timed : (mode ?? .timed), until: base.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func stop(reason: String? = nil) {
        guard active else { return }
        endTimer?.invalidate()
        warnTimer?.invalidate()
        mode = nil
        endsAt = nil
        release()
        syncClosedLid()
        AlertCenter.shared.dismiss(.awakeEnding)
        if let reason {
            AlertCenter.shared.post(NotchAlert(
                kind: .awakeOff, title: L("Đã tắt giữ máy thức", "Keep awake is off"), highlight: nil,
                subtitle: reason, icon: .symbol("cup.and.saucer"), tone: .neutral,
                priority: 0, duration: 4, action: .none))
        }
    }

    /// "1:23" hoặc "45p"; nil khi không có giờ kết thúc.
    func remainingText(now: Date = Date()) -> String? {
        guard let endsAt else { return nil }
        let minutes = max(0, Int(ceil(endsAt.timeIntervalSince(now) / 60)))
        return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : L("\(minutes)p", "\(minutes)m")
    }

    var statusText: String {
        switch mode {
        case nil: return L("Đang tắt", "Off")
        case .indefinite: return L("Giữ thức tới khi bạn tắt", "Awake until you turn it off")
        case let .app(_, name): return L("Giữ thức tới khi \(name) thoát", "Awake until \(name) quits")
        case .timed, .workEnd: return L("Giữ thức, còn \(remainingText() ?? "")", "Awake, \(remainingText() ?? "") left")
        }
    }

    private func begin(_ mode: Mode, until end: Date?) {
        if case let .app(pid, _) = mode, NSRunningApplication(processIdentifier: pid) == nil { return }
        self.mode = mode
        endsAt = end
        acquire()
        syncClosedLid()
        endTimer?.invalidate()
        warnTimer?.invalidate()
        AlertCenter.shared.dismiss(.awakeEnding)
        guard let end else { return }
        endTimer = Timer.scheduledTimer(withTimeInterval: max(1, end.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: L("Đã hết thời gian giữ thức.", "The keep awake time is up.")) }
        }
        endTimer?.tolerance = 5
        let warnIn = end.timeIntervalSinceNow - 120
        if warnIn > 1 {
            warnTimer = Timer.scheduledTimer(withTimeInterval: warnIn, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.warn() }
            }
            warnTimer?.tolerance = 2
        }
    }

    private func warn() {
        guard active else { return }
        AlertCenter.shared.post(NotchAlert(
            kind: .awakeEnding, title: L("Sắp hết giữ máy thức", "Keep awake ends soon"), highlight: L("2 phút", "2 min"),
            subtitle: L("Bấm vào đây để thêm 15 phút.", "Click here to add 15 minutes."),
            icon: .symbol("cup.and.saucer.fill"), tone: .yellow, priority: 1, duration: 10, action: .extendAwake))
    }

    private func acquire() {
        guard assertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Roost keep awake" as CFString, &assertion)
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    /// Gập máy mà không có màn rời mới tắt; có màn rời thì giữ tiếp (như Amphetamine).
    private func checkLid() {
        guard active, AlertSettings.shared.awakeStopOnLid, Self.lidClosed, !Self.hasExternalDisplay else { return }
        stop(reason: L("Bạn đã gập máy.", "The lid was closed."))
    }

    /// Chặn ngủ khi gập máy chỉ lúc đang giữ thức và có màn rời.
    func syncClosedLid() {
        let want = active && AlertSettings.shared.awakeClosedLid && Self.hasExternalDisplay && ClosedLidMode.installed
        ClosedLidMode.apply(want)
    }

    static var hasExternalDisplay: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// AppleClamshellState của IOPMrootDomain (đọc, không cần quyền).
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }
}

// MARK: - Gập máy có màn rời

/// macOS ngủ khi gập máy chạy pin, kể cả có màn rời; IOPMAssertion không chặn được. Cách duy nhất là
/// `pmset disablesleep 1` (cần root). Cài một lần quy tắc sudoers chỉ cho đúng 2 lệnh đó, rồi gọi `sudo -n`.
@MainActor
enum ClosedLidMode {
    static let sudoersPath = "/etc/sudoers.d/roost-pmset"
    private static let flagKey = "awake.sleepDisabledByRoost"
    private static var applied: Bool?

    static var installed: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    /// Hỏi mật khẩu admin một lần để cài quy tắc. Trả lỗi (nil = xong).
    static func install() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return L("Tên người dùng lạ, không cài được.", "Unusual user name, can't install.")
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let shell = "t=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' '\(rule)' > \"$t\" && /usr/sbin/visudo -cf \"$t\" "
            + "&& /usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath); r=$?; /bin/rm -f \"$t\"; exit $r"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error { return (error[NSAppleScript.errorMessage] as? String) ?? L("Không cài được.", "Install failed.") }
        KeepAwake.shared.syncClosedLid()
        return nil
    }

    static func apply(_ on: Bool, wait: Bool = false) {
        guard on != applied || wait else { return }
        guard installed else { applied = false; return }
        applied = on
        UserDefaults.standard.set(on, forKey: flagKey)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    static func resetIfLeftOn() {
        if UserDefaults.standard.bool(forKey: flagKey) { apply(false, wait: true) }
        applied = false
    }
}

// MARK: - Menu ly cà phê

/// Menu thả xuống của nút ly cà phê (NSMenu: notch giữ mở trong lúc menu hiện).
@MainActor
final class KeepAwakeMenu: NSObject {
    static let shared = KeepAwakeMenu()

    func pop() {
        let menu = NSMenu()
        fill(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Đổ các mục giữ máy thức vào `menu` (dùng cho nút ly cà phê và menu "⋯" của notch).
    func fill(_ menu: NSMenu) {
        let awake = KeepAwake.shared
        menu.autoenablesItems = false
        let status = NSMenuItem(title: awake.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if awake.active {
            if awake.endsAt != nil { menu.addItem(item(L("Thêm 15 phút", "Add 15 minutes"), #selector(add15))) }
            menu.addItem(item(L("Tắt giữ máy thức", "Turn off"), #selector(turnOff)))
        }
        menu.addItem(.separator())
        for m in [15, 30, 60, 120, 240, 480] {
            let title = m < 60 ? L("\(m) phút", "\(m) minutes") : L("\(m / 60) giờ", m == 60 ? "1 hour" : "\(m / 60) hours")
            let it = item(title, #selector(keepFor(_:)))
            it.tag = m
            menu.addItem(it)
        }
        menu.addItem(item(L("Tới khi tắt", "Until turned off"), #selector(keepForever)))
        let work = item(L("Tới giờ hết làm (\(AlertSettings.shared.workEndText))", "Until end of workday (\(AlertSettings.shared.workEndText))"),
                        #selector(keepWorkEnd))
        work.isEnabled = AlertSettings.shared.workEndToday != nil
        menu.addItem(work)
        let appsItem = NSMenuItem(title: L("Tới khi app thoát", "Until an app quits"), action: nil, keyEquivalent: "")
        let apps = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in running {
            let it = item(app.localizedName ?? "App", #selector(keepUntilQuit(_:)))
            it.representedObject = app
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                it.image = icon
            }
            apps.addItem(it)
        }
        appsItem.submenu = apps
        menu.addItem(appsItem)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    @objc private func add15() { KeepAwake.shared.extend(minutes: 15) }
    @objc private func turnOff() { KeepAwake.shared.stop() }
    @objc private func keepFor(_ sender: NSMenuItem) { KeepAwake.shared.keep(minutes: sender.tag) }
    @objc private func keepForever() { KeepAwake.shared.keepIndefinitely() }
    @objc private func keepWorkEnd() { KeepAwake.shared.keepUntilWorkEnd() }
    @objc private func keepUntilQuit(_ sender: NSMenuItem) {
        if let app = sender.representedObject as? NSRunningApplication { KeepAwake.shared.keep(until: app) }
    }
}

/// Nút ly cà phê trên hàng tab của notch đang mở. Đang giữ thức: ly sáng màu + thời gian còn lại.
struct KeepAwakeButton: View {
    @ObservedObject var awake = KeepAwake.shared

    var body: some View {
        Button { KeepAwakeMenu.shared.pop() } label: {
            HStack(spacing: 3) {
                Image(systemName: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 11, weight: .semibold))
                if awake.active, awake.endsAt != nil {
                    TimelineView(.everyMinute) { ctx in
                        Text(awake.remainingText(now: ctx.date) ?? "")
                            .font(.ui(10, weight: .semibold).monospacedDigit())
                    }
                }
            }
            .foregroundStyle(awake.active ? Self.activeColor : Self.idleColor)
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(awake.active ? awake.statusText : L("Giữ máy thức", "Keep awake"))
    }

    static var activeColor: Color {
        switch Theme.current {
        case .pixel: return PixelPalette.pink
        case .cassette: return CassettePalette.band
        case .vangogh: return VG.yellow
        case .standard: return Color(red: 1, green: 0.72, blue: 0.3)
        }
    }
    static var idleColor: Color {
        Theme.isCassette ? CassettePalette.label.opacity(0.6) : Theme.isVanGogh ? VG.cream.opacity(0.7) : .white.opacity(0.5)
    }
}
