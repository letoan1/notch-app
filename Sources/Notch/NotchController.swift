import AppKit
import SwiftUI

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
    private let panel: NotchPanel
    private var screen: NSScreen
    private var hoverTimer: Timer?
    private var lastInside = Date.distantPast
    // Theo dõi kéo file toàn hệ thống: cửa sổ đang ignoresMouseEvents nên không tự nhận drag.
    private var wasLeftDown = false
    private var dragCountAtMouseDown = 0
    private var fileDragActive = false

    init() {
        screen = Self.targetScreen()
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.canvas))
        panel.contentView = FirstMouseHostingView(rootView: NotchRootView(model: model, media: media, permissions: permissions,
                                                                  tray: tray, calendar: calendar))
        panel.ignoresMouseEvents = true
        layout()
        panel.orderFrontRegardless()

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

    /// Ưu tiên màn hình có notch thật, không có thì dùng màn hình chính (notch giả).
    private static func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func layout() {
        screen = Self.targetScreen()
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
        let leftDown = updateDragState()
        let mouse = NSEvent.mouseLocation
        let size = model.shapeSize(playing: media.hasTrack)
        let f = screen.frame
        // Đang kéo file thì nới vùng bắt rộng hơn cho dễ "ném" vào notch.
        let margin: (CGFloat, CGFloat) = fileDragActive && !model.expanded ? (40, 30) : (4, 4)
        let hot = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                         width: size.width, height: size.height)
            .insetBy(dx: -margin.0, dy: -margin.1)

        if hot.contains(mouse) {
            lastInside = Date()
            if !model.expanded {
                if fileDragActive { model.tab = .tray }
                setExpanded(true)
            }
        } else if model.expanded, !leftDown, Date().timeIntervalSince(lastInside) > 0.25 {
            // Không thu lại khi chuột còn giữ: đang kéo file ra khỏi khay.
            setExpanded(false)
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

        // Bỏ quán tính để một lần vuốt chỉ chuyển một tuần.
        if !event.momentumPhase.isEmpty { return nil }
        if event.phase == .began { scrollAccum = 0 }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        scrollAccum += (abs(dx) > abs(dy) ? dx : dy) * scale

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
            model.dropTargeted = false
            calendar.resetToToday()
        }
        panel.ignoresMouseEvents = !value
    }
}
