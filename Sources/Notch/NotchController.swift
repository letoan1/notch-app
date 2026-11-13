import AppKit
import SwiftUI
import Combine

/// Cửa sổ trong suốt phủ vùng notch, nằm trên menu bar.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Chỉ nhận bàn phím khi đang có câu hỏi của Claude (ô "Khác…"); còn lại click không lấy focus
    /// khỏi app đang dùng.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    // Không để AppKit đẩy cửa sổ xuống dưới menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    static let canvas = CGSize(width: 760, height: 320)

    let model = NotchModel()
    let media = NowPlaying()
    let permissions = PermissionCenter()
    let tray = TrayStore()
    let calendar = CalendarStore()
    let camera = CameraMirror()
    private let panel: NotchPanel
    private var screen: NSScreen
    private var hoverTimer: Timer?
    private var lastInside = Date.distantPast
    // Theo dõi kéo file toàn hệ thống: cửa sổ đang ignoresMouseEvents nên không tự nhận drag.
    private var wasLeftDown = false
    private var dragCountAtMouseDown = 0
    private var fileDragActive = false

    private let settings = SettingsStore.shared
    private let hotKey = HotKey()
    private var cancellables = Set<AnyCancellable>()
    /// Menu chuột phải đang mở: giữ notch, không thu lại (thu lại sẽ đóng menu).
    private var menuTracking = false
    /// Mở bằng phím tắt: giữ mở tới khi bấm lại phím tắt hoặc chuột vào rồi rời notch.
    private var pinned = false
    private var hoverStart: Date?

    init() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens[0]
        Theme.registerFonts()
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.canvas))
        panel.contentView = makeRootView()
        panel.ignoresMouseEvents = true
        layout()
        panel.orderFrontRegardless()

        // @Published phát trước khi gán → receive(on:) để đọc giá trị mới.
        settings.$language.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildRootView() }
        }.store(in: &cancellables)
        settings.$theme.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildRootView() }
        }.store(in: &cancellables)
        settings.$hotkey.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotkey() }
        }.store(in: &cancellables)
        settings.$displayMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }.store(in: &cancellables)
        hotKey.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.toggleFromHotkey() }
        }
        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true),
                                 (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTracking = tracking }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }

        // Poll vị trí chuột thay vì global event monitor: không cần quyền Accessibility.
        scheduleHover(Self.fastPoll)
        // Vuốt trackpad / lăn chuột trên vùng lịch → chuyển tuần.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) ?? event }
        }
        media.start()
        permissions.start()
        battery.onPlugIn = { [weak self] status in
            MainActor.assumeIsolated { self?.showChargePeek(status) }
        }
        battery.start()
    }

    private func makeRootView() -> NSView {
        FirstMouseHostingView(rootView: NotchRootView(model: model, media: media, permissions: permissions,
                                                      tray: tray, calendar: calendar, camera: camera,
                                                      settings: settings))
    }

    /// Đổi ngôn ngữ: dựng lại toàn bộ view để mọi chuỗi L(...) được tính lại.
    private func rebuildRootView() {
        panel.contentView = makeRootView()
    }

    private func applyHotkey() {
        if let (code, mods) = settings.hotkey.carbon {
            hotKey.register(keyCode: code, modifiers: mods)
        } else {
            hotKey.unregister()
        }
    }

    private func toggleFromHotkey() {
        if model.expanded {
            setExpanded(false)
        } else {
            pinned = true
            setExpanded(true)
        }
    }

    private static var primaryScreen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Màn hình hiện notch theo cài đặt; màn hình không có notch thật thì vẽ notch giả.
    private func targetScreen() -> NSScreen {
        switch settings.displayMode {
        case .notch:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? Self.primaryScreen
        case .main:
            return Self.primaryScreen
        case .mouse:
            return Self.screen(containing: NSEvent.mouseLocation) ?? Self.primaryScreen
        }
    }

    private func layout() {
        screen = targetScreen()
        model.update(for: screen)
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - Self.canvas.width / 2,
                              y: f.maxY - Self.canvas.height,
                              width: Self.canvas.width,
                              height: Self.canvas.height),
                       display: true)
    }

    private func tick() {
        let isQuestion = permissions.current?.questions?.isEmpty == false
        if model.tall != isQuestion { model.tall = isQuestion }
        let wantMirror = model.tab == .mirror
        if model.mirrorMode != wantMirror { model.mirrorMode = wantMirror }
        panel.allowsKey = isQuestion
        if !isQuestion, panel.isKeyWindow {
            // Trả bàn phím về app đang dùng (VS Code…) ngay khi hết câu hỏi.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        // Có yêu cầu quyền đang chờ: giữ notch mở cho tới khi bấm hoặc hook hết giờ.
        if permissions.current != nil {
            lastInside = Date()
            if !model.expanded { setExpanded(true) }
            return
        }
        if menuTracking {
            lastInside = Date()
            return
        }
        // Tab đang chọn bị tắt trong Cài đặt → chuyển sang tab bật đầu tiên.
        let tabs = settings.enabledTabs
        if let first = tabs.first, !tabs.contains(model.tab) { model.tab = first }

        let wasDown = wasLeftDown
        let leftDown = updateDragState()
        let pressBegan = leftDown && !wasDown
        let mouse = NSEvent.mouseLocation
        // "Theo con trỏ": notch nhảy sang màn hình có chuột (chỉ khi đang thu gọn).
        if settings.displayMode == .mouse, !model.expanded,
           let under = Self.screen(containing: mouse), under != screen {
            layout()
        }
        let size = model.shapeSize(playing: media.hasTrack)
        let f = screen.frame
        // Đang kéo file thì nới vùng bắt rộng hơn cho dễ "ném" vào notch.
        let margin: (CGFloat, CGFloat) = fileDragActive && !model.expanded ? (40, 30) : (4, 4)
        let hot = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                         width: size.width, height: size.height)
            .insetBy(dx: -margin.0, dy: -margin.1)

        if hot.contains(mouse) {
            lastInside = Date()
            pinned = false
            if !model.expanded {
                if fileDragActive {
                    if settings.showTray { model.tab = .tray }
                    setExpanded(true)
                } else if settings.openMode == .click {
                    if pressBegan { setExpanded(true) }
                } else {
                    let start = hoverStart ?? Date()
                    hoverStart = start
                    if Date().timeIntervalSince(start) >= settings.hoverDelay { setExpanded(true) }
                }
            }
        } else {
            hoverStart = nil
            if model.expanded, !pinned, !leftDown, Date().timeIntervalSince(lastInside) > 0.25 {
                // Không thu lại khi chuột còn giữ: đang kéo file ra khỏi khay.
                setExpanded(false)
            }
        }

        // Chuột ở xa notch thì poll thưa để CPU được ngủ; lại gần / đang kéo thì 60Hz.
        let near = model.expanded || leftDown
            || (abs(mouse.x - f.midX) < 260 && mouse.y > f.maxY - 140)
        scheduleHover(near ? Self.fastPoll : Self.slowPoll)
    }

    private let battery = BatteryMonitor()
    private var peekToken = 0

    private func showChargePeek(_ status: BatteryMonitor.Status) {
        guard !model.expanded else { return }
        peekToken += 1
        let token = peekToken
        model.chargePeek = .init(percent: status.percent, charging: status.charging)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.peekToken == token else { return }
                self.model.chargePeek = nil
            }
        }
    }

    private var scrollMonitor: Any?
    private var scrollAccum: CGFloat = 0
    private var lastWeekShift = Date.distantPast

    /// Trả nil = đã xử lý (nuốt event), trả event = để hệ thống xử lý tiếp.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, model.expanded, model.tab == .media,
              permissions.current == nil, calendar.access == .granted
        else { return event }

        // Chỉ vùng lịch: bên phải cột nhạc (340pt), dưới hàng tab.
        let mouse = NSEvent.mouseLocation
        let f = screen.frame
        let left = f.midX - NotchModel.expandedWidth / 2 + 14 + 341
        guard mouse.x > left, mouse.x < f.midX + NotchModel.expandedWidth / 2,
              mouse.y < f.maxY - model.notchSize.height
        else { return event }

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let horizontal = abs(dx) > abs(dy)
        // Dải ngày + tiêu đề tháng (~78pt dưới hàng tab): cuộn dọc ở đây cũng đổi tuần.
        // Dưới đó là danh sách sự kiện: cuộn dọc để danh sách tự cuộn.
        let inWeekStrip = mouse.y >= f.maxY - model.notchSize.height - 78
        if !horizontal && !inWeekStrip { return event }

        // Bỏ quán tính để một lần vuốt chỉ chuyển một tuần.
        if !event.momentumPhase.isEmpty { return nil }
        if event.phase == .began { scrollAccum = 0 }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        scrollAccum += (horizontal ? dx : dy) * scale

        guard abs(scrollAccum) > 30, Date().timeIntervalSince(lastWeekShift) > 0.35 else { return nil }
        calendar.shiftWeek(scrollAccum < 0 ? 1 : -1)
        scrollAccum = 0
        lastWeekShift = Date()
        return nil
    }

    private static let fastPoll: TimeInterval = 1.0 / 60
    private static let slowPoll: TimeInterval = 0.1
    private var hoverInterval: TimeInterval = 0

    private func scheduleHover(_ interval: TimeInterval) {
        guard interval != hoverInterval else { return }
        hoverInterval = interval
        hoverTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        hoverTimer = timer
    }

    /// Trả về chuột trái có đang giữ không; cập nhật `fileDragActive`.
    private func updateDragState() -> Bool {
        let leftDown = NSEvent.pressedMouseButtons & 1 != 0
        if leftDown {
            let pasteboard = NSPasteboard(name: .drag)
            if !wasLeftDown {
                dragCountAtMouseDown = pasteboard.changeCount
            } else if !fileDragActive, pasteboard.changeCount != dragCountAtMouseDown {
                fileDragActive = pasteboard.types?.contains(.fileURL) == true
            }
        } else {
            fileDragActive = false
        }
        wasLeftDown = leftDown
        return leftDown
    }

    private func setExpanded(_ value: Bool) {
        model.expanded = value
        if !value {
            pinned = false
            model.dropTargeted = false
            calendar.resetToToday()
        }
        panel.ignoresMouseEvents = !value
    }
}
