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
        applySharing()
    }

    func applySharing() { sharingType = SettingsStore.shared.hideInScreenShare ? .none : .readOnly }

    /// Chỉ nhận bàn phím khi đang có câu hỏi của Claude (ô "Khác…"); còn lại click không lấy focus
    /// khỏi app đang dùng.
    var allowsKey = false
    /// Tab Ngân hàng đang mở: bấm vào ô số tiền thì nhận bàn phím (không tự giành focus).
    var allowsBankKey = false
    override var canBecomeKey: Bool { allowsKey || allowsBankKey }
    override var canBecomeMain: Bool { false }
    // Không để AppKit đẩy cửa sổ xuống dưới menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Notch trên 1 màn hình: panel + model riêng (mở/thu, kích thước notch), dữ liệu dùng chung.
@MainActor
final class NotchSlot {
    let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchController.canvas))
    let model = NotchModel()
    var screen: NSScreen

    private var bankSink: AnyCancellable?

    init(screen: NSScreen) {
        self.screen = screen
        panel.ignoresMouseEvents = true
        let panel = self.panel
        bankSink = model.$tab.combineLatest(model.$expanded).sink { tab, expanded in
            panel.allowsBankKey = expanded && tab == .bank
        }
    }

    func place() {
        model.update(for: screen)
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - NotchController.canvas.width / 2,
                              y: f.maxY - NotchController.canvas.height,
                              width: NotchController.canvas.width,
                              height: NotchController.canvas.height),
                       display: true)
        panel.orderFrontRegardless()
    }
}

@MainActor
final class NotchController {
    // Đủ rộng cho notch mở cỡ Rộng (620 × 1,15) cộng hai cột nút tròn hai bên.
    /// Cao đủ cho thẻ câu hỏi 2 hàng lựa chọn ở cỡ Rộng (32 + 252 × 1,15 ≈ 322).
    static let canvas = CGSize(width: 840, height: 340)

    /// Thẻ câu hỏi: 1 hàng lựa chọn (≤ 2) vừa 222pt; 2 hàng có mô tả 2 dòng cần ~240pt nên cho 252pt.
    /// Pixel xếp lựa chọn thành dòng chữ gọn nên luôn vừa 222pt.
    static func questionBodyHeight(_ questions: [AskQuestion]) -> CGFloat {
        if Theme.isPixel { return NotchModel.tallBodyHeight }
        // Ô lựa chọn rộng ~270pt: mô tả quá ~45 ký tự (cỡ 10) hoặc câu hỏi quá ~70 ký tự sẽ xuống dòng.
        let crowded = questions.contains { q in
            (q.options.count + 1) / 2 >= 2 && (q.text.count > 70 || q.options.contains { $0.description.count > 45 })
        }
        return crowded ? 252 : NotchModel.tallBodyHeight
    }

    let media = NowPlaying()
    let permissions = PermissionCenter()
    let tray = TrayStore()
    let calendar = CalendarStore()
    let camera = CameraMirror()
    /// Mỗi màn hình hiện notch có 1 slot; chế độ "Tất cả màn hình" thì nhiều slot cùng lúc.
    private var slots: [NotchSlot] = []
    /// Slot dưới chuột / đang mở. Chỉ slot này được mở, các slot khác giữ thu gọn.
    private var active: NotchSlot!
    private var model: NotchModel { active.model }
    private var panel: NotchPanel { active.panel }
    private var screen: NSScreen { active.screen }
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
    private var mouseMonitors: [Any] = []

    init() {
        Theme.registerFonts()
        layout()

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
        settings.$noNotchStyle.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }.store(in: &cancellables)
        // Chuột theo sự kiện (không cần quyền Accessibility): notch thu gọn + chuột đứng yên = không thức dậy.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.tick() }
            return event
        }) { mouseMonitors.append(local) }
        // Chọn file trong khay → panel nhận bàn phím (Space = Xem nhanh), bỏ chọn → trả lại.
        tray.$selection.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeyFocus() }
        }.store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
        // Yêu cầu của Claude tới lúc chuột đứng yên vẫn phải mở notch.
        permissions.$requests.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }.store(in: &cancellables)
        // Mở / đóng từ script (kiểm thử, phím tắt bên ngoài): DistributedNotificationCenter, không phải notifyutil.
        // osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter
        //   .postNotificationNameObjectUserInfoDeliverImmediately("io.github.letoan1.roost.toggle", $(), $(), true)'
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.letoan1.roost.toggle"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleFromHotkey() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.letoan1.roost.onboarding"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OnboardingWindowController.shared.show() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.letoan1.roost.settings"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsWindowController.shared.show() }
        }
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
        LyricsStore.shared.bind(media)
        permissions.start()
        battery.onPlugIn = { [weak self] status in
            MainActor.assumeIsolated {
                self?.showPeek(.charge(.init(percent: status.percent, charging: status.charging)))
            }
        }
        battery.start()
        audio.onHeadphonesChange = { on in
            MainActor.assumeIsolated {
                PetState.shared.wearingHeadphones = on
                BluetoothAudio.shared.refresh()
            }
        }
        audio.onConnect = { [weak self] device in
            MainActor.assumeIsolated {
                if self?.settings.showPet == true { PetState.shared.react(.headphones) }
                BluetoothBattery.level(named: device.name) { level in
                    DispatchQueue.main.async {
                        AlertCenter.shared.post(NotchAlert(
                            kind: .device, title: device.name, highlight: nil, subtitle: L("Đã kết nối", "Connected"),
                            icon: .symbol(device.symbol), tone: .neutral, priority: 0, duration: 3.5, action: .none,
                            ring: level))
                    }
                }
            }
        }
        audio.start()
        SystemMonitor.shared.start(battery: battery)
        SystemMonitor.shared.$fullscreenDisplays.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMinimal() }
        }.store(in: &cancellables)
        SystemMonitor.shared.$lowPower.receive(on: DispatchQueue.main).sink { [weak self] low in
            MainActor.assumeIsolated {
                AudioSpectrum.suppressed = low
                self?.media.syncSpectrum()
            }
        }.store(in: &cancellables)
        media.$track.receive(on: DispatchQueue.main).sink { [weak self] track in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePet()
                // Đổi bài khi đang phát → nhảy mừng.
                let title = track?.title
                if let title, title != self.lastTitle, self.lastTitle != nil, track?.isPlaying == true, self.settings.showPet {
                    PetState.shared.react(.happy)
                }
                self.lastTitle = title
            }
        }.store(in: &cancellables)
        tray.$files.receive(on: DispatchQueue.main).sink { [weak self] files in
            MainActor.assumeIsolated {
                guard let self else { return }
                if files.count > self.lastTrayCount, self.settings.showPet { PetState.shared.react(.happy) }
                self.lastTrayCount = files.count
            }
        }.store(in: &cancellables)
        // Thả file lên notch: bay vào khay rồi mới thêm (ô mới nảy ra, badge nảy, notch "nuốt").
        tray.onDrop = { [weak self] urls, point in
            MainActor.assumeIsolated { self?.flyIntoTray(urls, from: point) }
        }
        PetState.shared.startIdleActions()
        // Kiểm tra "rảnh lâu → ngủ" thưa: 30s/lần.
        petTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePet() }
        }
        petTimer?.tolerance = 5
        screenshots.onNew = { [weak self] url, thumb in
            MainActor.assumeIsolated {
                guard let self, self.settings.screenshotsToTray, self.settings.showTray else { return }
                self.tray.add(url)
                self.showPeek(.screenshot(thumb))
            }
        }
        screenshots.keep = { [weak self] in
            MainActor.assumeIsolated { self?.tray.files ?? [] }
        }
        settings.$screenshotsToTray.combineLatest(settings.$showTray).receive(on: DispatchQueue.main).sink { [weak self] on, tray in
            MainActor.assumeIsolated { self?.screenshots.setEnabled(on && tray) }
        }.store(in: &cancellables)
        // Mở khoá bằng khuôn mặt: lời chào sau khi mở khoá (mọi cách). Debug notification không tới được đây.
        FaceUnlockController.shared.onUnlock = { [weak self] name in
            MainActor.assumeIsolated { self?.showPeek(.unlocked(name)) }
        }
        FaceUnlockController.shared.start()
        // Claude: phiên chờ bạn / hạn mức đặt lại → thông báo nhanh; nhạc trên màn hình khoá.
        permissions.onNotice = { [weak self] notice in self?.showPeek(.claude(notice)) }
        ClaudeUsage.shared.onReset = { [weak self] w in self?.showPeek(.claude(.reset(w))) }
        LockScreenMusic.shared.start(media: media)
        SoundCenter.shared.start()
        startSystemAlerts()
        settings.$realVisualizer.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.media.syncSpectrum() }
        }.store(in: &cancellables)
    }

    private func makeRootView(_ model: NotchModel) -> NSView {
        FirstMouseHostingView(rootView: NotchRootView(model: model, media: media, permissions: permissions,
                                                      tray: tray, calendar: calendar, camera: camera,
                                                      settings: settings))
    }

    /// Đổi ngôn ngữ: dựng lại toàn bộ view để mọi chuỗi L(...) được tính lại.
    private func rebuildRootView() {
        for slot in slots { slot.panel.contentView = makeRootView(slot.model) }
    }

    private func applyHotkey() {
        if let (code, mods) = settings.hotkey.carbon {
            hotKey.register(keyCode: code, modifiers: mods)
        } else {
            hotKey.unregister()
        }
    }

    private func toggleFromHotkey() {
        if !model.expanded { activateSlotUnderMouse() }
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
        case .main, .all:
            return Self.primaryScreen
        case .mouse:
            return Self.screen(containing: NSEvent.mouseLocation) ?? Self.primaryScreen
        }
    }

    /// Dựng slot theo cài đặt: 1 notch, hoặc mỗi màn hình 1 notch. Giữ lại panel cũ khi được.
    private func layout() {
        let all = settings.displayMode == .all
        let screens = all ? NSScreen.screens : [targetScreen()]
        var pool = slots
        var kept: [NotchSlot] = []
        for target in screens {
            let slot: NotchSlot
            if let i = pool.firstIndex(where: { $0.screen.displayID == target.displayID }) {
                slot = pool.remove(at: i)
            } else if !all, !pool.isEmpty {
                slot = pool.removeFirst()   // chế độ 1 notch: dời panel sang màn hình mới
            } else {
                slot = NotchSlot(screen: target)
                slot.panel.contentView = makeRootView(slot.model)
            }
            slot.screen = target
            slot.place()
            kept.append(slot)
        }
        for slot in pool { slot.panel.orderOut(nil) }
        defer { applyMinimal() }
        let previous = active
        slots = kept
        if previous == nil || !kept.contains(where: { $0 === previous }) {
            active = slot(under: NSEvent.mouseLocation) ?? kept[0]
            if let previous { active.model.tab = previous.model.tab }
        }
    }

    private func slot(under point: NSPoint) -> NotchSlot? {
        guard let id = Self.screen(containing: point)?.displayID else { return nil }
        return slots.first { $0.screen.displayID == id }
    }

    /// Chuột sang màn hình khác (notch đang thu): chuyển quyền tương tác sang notch màn đó.
    private func activateSlotUnderMouse() {
        guard slots.count > 1, !model.expanded,
              let next = slot(under: NSEvent.mouseLocation), next !== active else { return }
        next.model.tab = model.tab
        hoverStart = nil
        active = next
    }

    private func tick() {
        capsLock.check()
        activateSlotUnderMouse()
        updatePet()
        let questions = permissions.current?.questions ?? []
        let isQuestion = !questions.isEmpty
        if model.tall != isQuestion { model.tall = isQuestion }
        let questionHeight = Self.questionBodyHeight(questions)
        if isQuestion, model.tallHeight != questionHeight { model.tallHeight = questionHeight }
        let wantMirror = model.tab == .mirror
        if model.mirrorMode != wantMirror { model.mirrorMode = wantMirror }
        updateKeyFocus()
        // Có yêu cầu quyền đang chờ: giữ notch mở cho tới khi bấm hoặc hook hết giờ.
        if permissions.current != nil {
            lastInside = Date()
            if !model.expanded { setExpanded(true) }
            scheduleHover(Self.fastPoll)
            return
        }
        // Menu chuột phải hoặc Quick Look đang mở: giữ notch mở (chuột rời notch để xem Quick Look là bình thường).
        if menuTracking || TrayQuickLook.shared.isActive {
            lastInside = Date()
            TrayQuickLook.shared.checkClosed()
            return
        }
        // Tab đang chọn bị tắt trong Cài đặt → chuyển sang tab bật đầu tiên.
        let tabs = settings.enabledTabs
        if let first = tabs.first, !tabs.contains(model.tab) { model.tab = first }

        let wasDown = wasLeftDown
        let leftDown = updateDragState()
        let pressBegan = leftDown && !wasDown
        let mouse = NSEvent.mouseLocation
        recordPointer(mouse)
        // "Theo con trỏ": notch nhảy sang màn hình có chuột (chỉ khi đang thu gọn).
        if settings.displayMode == .mouse, !model.expanded,
           let under = Self.screen(containing: mouse), under.displayID != screen.displayID {
            layout()
        }
        let size = model.shapeSize(wing: wingLayout().width)
        let f = screen.frame
        // Đang kéo file thì nới vùng bắt rộng hơn cho dễ "ném" vào notch.
        let margin: (CGFloat, CGFloat) = fileDragActive && !model.expanded ? (40, 30) : (4, 4)
        // Viên nổi: vùng bắt kéo lên tận mép trên (hất chuột lên đỉnh màn hình vẫn mở).
        // Notch mở có cột nút tròn hai bên: rê chuột sang nút không làm notch đóng.
        let layoutStore = NotchLayoutStore.shared
        let orbL = model.expanded && !model.minimal ? layoutStore.orbInset(.left) : 0
        let orbR = model.expanded && !model.minimal ? layoutStore.orbInset(.right) : 0
        let hot = NSRect(x: f.midX - size.width / 2 + model.shapeOffsetX - orbL, y: f.maxY - size.height - model.topGap,
                         width: size.width + orbL + orbR, height: size.height + model.topGap)
            .insetBy(dx: -margin.0, dy: -margin.1)

        // Thẻ thông báo đang hiện: rê chuột lên thì giữ thẻ, bấm thì chạy hành động (không mở notch).
        if model.alert != nil, !model.expanded {
            let inside = hot.contains(mouse)
            AlertCenter.shared.setHovering(inside)
            if inside { lastInside = Date() }
            if inside, pressBegan { AlertCenter.shared.activate() }
            scheduleHover(Self.fastPoll)
            return
        }
        if hot.contains(mouse) {
            lastInside = Date()
            pinned = false
            if !model.expanded, !model.minimal || fileDragActive {
                if fileDragActive {
                    if settings.showTray { model.tab = .tray }
                    setExpanded(true)
                } else if settings.openMode == .click {
                    if pressBegan { setExpanded(true) }
                } else {
                    let start = hoverStart ?? Date()
                    hoverStart = start
                    let dwell = Date().timeIntervalSince(start)
                    if settings.hoverDelay < 0 ? hoverIntent(dwell: dwell) : dwell >= settings.hoverDelay {
                        setExpanded(true)
                    }
                }
            }
        } else {
            hoverStart = nil
            if model.expanded, !pinned, !leftDown, Date().timeIntervalSince(lastInside) > Self.closeGrace {
                // Không thu lại khi chuột còn giữ: đang kéo file ra khỏi khay.
                setExpanded(false)
            }
        }

        // Chuột ở xa notch thì poll thưa để CPU được ngủ; lại gần / đang kéo thì 60Hz.
        // Timer chỉ khi đang bận (notch mở / giữ chuột / chờ độ trễ hover); còn lại sống bằng sự kiện chuột.
        let busy = model.expanded || leftDown || hoverStart != nil
        scheduleHover(busy ? Self.fastPoll : nil)
    }

    // MARK: - Bàn phím

    private var keyMonitor: Any?

    /// Khay đang có file được chọn (notch mở, tab khay, không có thẻ Claude).
    private var trayWantsKey: Bool {
        model.expanded && model.tab == .tray && permissions.current == nil && !tray.selection.isEmpty
    }

    /// Panel chỉ nhận bàn phím khi Claude hỏi (ô "Khác…") hoặc khay đang chọn file.
    private func updateKeyFocus() {
        guard active != nil else { return }
        let isQuestion = permissions.current?.questions?.isEmpty == false
        // Tab Ngân hàng có ô nhập số tiền: cho phép nhận bàn phím khi bấm vào ô, nhưng không tự giành focus.
        let bank = model.expanded && model.tab == .bank
        let wantsKey = isQuestion || (trayWantsKey && !TrayQuickLook.shared.isActive)
        panel.allowsKey = wantsKey
        // Quick Look đang mở (kể cả lúc còn chạy hiệu ứng hiện ra): không giành key, nếu không nó tự đóng.
        if trayWantsKey, !panel.isKeyWindow, !TrayQuickLook.shared.isActive {
            panel.makeKey()
        } else if !wantsKey, !bank, panel.isKeyWindow {
            // Trả bàn phím về app đang dùng (VS Code…) ngay khi hết câu hỏi / bỏ chọn.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// Space = Xem nhanh, Esc = bỏ chọn, ⌘A = chọn hết (trong khay).
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, trayWantsKey else { return event }
        switch event.keyCode {
        case 49 where event.isARepeat:
            return nil   // giữ Space: không bật / tắt liên tục
        case 49:
            TrayQuickLook.shared.toggle(tray.visibleFiles.filter(tray.selection.contains))
            return nil
        case 53:
            tray.selection = []
            return nil
        case 0 where event.modifierFlags.contains(.command):
            tray.selection = Set(tray.visibleFiles)
            return nil
        default:
            return event
        }
    }

    // MARK: - File bay vào khay

    private func flyIntoTray(_ urls: [URL], from point: NSPoint) {
        let model = self.model
        let screen = self.screen
        if tray.filter != .all { tray.filter = .all }
        let base = tray.files.count
        var gulpToken = 0
        FlyIn.run(urls: urls, from: point, on: screen, target: { [weak self] i in
            self?.traySlotPoint(base + i, model: model, screen: screen) ?? point
        }, arrive: { [weak self] url in
            guard let self else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { self.tray.add(url) }
            gulpToken += 1
            let token = gulpToken
            model.gulp = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                if token == gulpToken { model.gulp = false }
            }
        })
    }

    /// Ước lượng tâm ô thứ `index` trong khay đang mở (toạ độ màn hình); ô ngoài vùng cuộn thì kẹp ở mép phải.
    private func traySlotPoint(_ index: Int, model: NotchModel, screen: NSScreen) -> NSPoint {
        let f = screen.frame
        let s = NotchModel.scale
        let cassette = Theme.isCassette
        let contentWidth = NotchModel.expandedWidth - 28
        let inner = f.midX - contentWidth / 2 * s
        let pad: CGFloat = cassette ? 18 : 20
        let tile: CGFloat = cassette ? 112 : 84
        let gap: CGFloat = cassette ? 10 : 14
        let zone: CGFloat = (cassette ? 170 : 150) + (cassette ? 14 : 16)
        let maxX = contentWidth - pad - zone - tile / 2
        let x = min(pad + 2 + CGFloat(index) * (tile + gap) + tile / 2, maxX)
        let filterBar: CGFloat = tray.filterCounts.isEmpty ? 0 : 18
        let y = model.notchSize.height + 6 + filterBar + (cassette ? 44 : 45)
        return NSPoint(x: inner + x * s, y: f.maxY - model.topGap - y * s)
    }

    // MARK: - Hover thông minh

    /// Vị trí chuột gần đây (chỉ ~0.1s cuối) để ước tốc độ.
    private var pointerSamples: [(t: TimeInterval, p: NSPoint)] = []

    private func recordPointer(_ p: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        pointerSamples.append((now, p))
        if let i = pointerSamples.firstIndex(where: { now - $0.t <= 0.1 }), i > 0 {
            pointerSamples.removeFirst(i)
        }
    }

    /// pt/s trên ~0.1s cuối; nil khi chưa đủ mẫu (vừa có sự kiện đầu tiên sau lúc đứng yên).
    private func pointerSpeed() -> CGFloat? {
        guard let first = pointerSamples.first, let last = pointerSamples.last else { return nil }
        let dt = last.t - first.t
        guard dt >= 0.025 else { return nil }
        return hypot(last.p.x - first.p.x, last.p.y - first.p.y) / CGFloat(dt)
    }

    /// Mở khi chuột chậm lại trên notch hoặc nán lại; lướt nhanh qua (tới icon menu bar cạnh notch) thì không.
    private func hoverIntent(dwell: TimeInterval) -> Bool {
        let speed = pointerSpeed()
        if let speed, speed < Self.intentSpeed { return true }
        if dwell >= 0.12, (speed ?? 0) < Self.dwellSpeed { return true }
        return dwell >= 0.45
    }

    private static let intentSpeed: CGFloat = 320
    private static let dwellSpeed: CGFloat = 900

    private let battery = BatteryMonitor()
    private var peekToken = 0

    private let audio = AudioDeviceMonitor()

    /// Màn hình đang toàn màn hình → notch tối giản; màn không có notch thật thì ẩn hẳn notch vẽ
    /// (trừ khi đang mở: phím tắt / Claude hỏi).
    private func applyMinimal() {
        let full = SystemMonitor.shared.fullscreenDisplays
        for slot in slots {
            let minimal = slot.screen.displayID.map(full.contains) ?? false
            if slot.model.minimal != minimal { slot.model.minimal = minimal }
            let hidden = minimal && !slot.model.expanded && slot.screen.safeAreaInsets.top == 0
            slot.panel.alphaValue = hidden ? 0 : 1
        }
    }
    private var petTimer: Timer?
    private var lastTitle: String?
    private var lastTrayCount = Int.max

    /// Mood thú cưng theo sự kiện: Claude hỏi > có nhạc > rảnh lâu thì ngủ > ngồi chơi.
    /// Mắt nhìn theo con trỏ.
    private func updatePet() {
        guard settings.showPet, active != nil else { return }
        let f = screen.frame
        let petX: CGFloat
        if model.expanded {
            petX = f.midX + (NotchModel.expandedWidth / 2 - 95) * NotchModel.scale
        } else {
            let w = model.shapeSize(wing: wingLayout().width).width
            petX = f.midX + model.shapeOffsetX + w / 2 - model.topRadius - model.petWing / 2
        }
        PetState.shared.setLook((NSEvent.mouseLocation.x - petX) / 220)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        let mood: PetMood = permissions.current != nil ? .alert
            : media.isPlaying ? .dance
            : idle > 120 ? .sleep : .idle
        if PetState.shared.mood != mood { PetState.shared.mood = mood }
    }
    private let screenshots = ScreenshotWatcher()
    private let batteryAlerts = BatteryAlerts()
    private let network = NetworkWatcher()
    private let capsLock = CapsLockWatcher()
    private let downloads = DownloadsWatcher()

    /// Pin, mất mạng, Caps Lock, file tải về, giữ máy thức: tất cả theo sự kiện.
    private func startSystemAlerts() {
        AlertCenter.shared.apply = { [weak self] alert in
            guard let self else { return false }
            guard let alert else {
                for slot in self.slots where slot.model.alert != nil { slot.model.alert = nil }
                return true
            }
            var shown = false
            for slot in self.slots where !slot.model.expanded && (!slot.model.minimal || alert.priority >= 2) {
                slot.model.alert = alert
                shown = true
            }
            if shown { self.scheduleHover(Self.fastPoll) }
            return shown
        }
        batteryAlerts.start()
        network.start()
        capsLock.onChange = { [weak self] on in self?.showPeek(.capsLock(on)) }
        SystemHUD.shared.show = { [weak self] hud in
            guard let self, !self.model.expanded,
                  self.slots.contains(where: { !$0.model.expanded && !$0.model.minimal && $0.model.alert == nil }) else { return false }
            self.showPeek(.hud(hud), duration: 1.6)
            return true
        }
        SystemHUD.shared.start()
        PermissionWatch.shared.start()
        capsLock.start()
        downloads.onFile = { [weak self] url in
            guard let self, self.settings.showTray else { return }
            self.tray.add(url)
            let thumb: NSImage? = ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(url.pathExtension.lowercased())
                ? NSImage(contentsOf: url) : NSWorkspace.shared.icon(forFile: url.path)
            self.showPeek(.screenshot(thumb))
        }
        AlertSettings.shared.$downloadsToTray.combineLatest(settings.$showTray).receive(on: DispatchQueue.main).sink { [weak self] on, tray in
            MainActor.assumeIsolated { self?.downloads.setEnabled(on && tray) }
        }.store(in: &cancellables)
        KeepAwake.shared.start()
        SystemMonitor.shared.$batteryPercent.combineLatest(SystemMonitor.shared.$batteryCharging)
            .receive(on: DispatchQueue.main).sink { percent, onAC in
                MainActor.assumeIsolated { KeepAwake.shared.batteryChanged(percent: percent, onAC: onAC) }
            }.store(in: &cancellables)
    }

    private func showPeek(_ peek: NotchModel.Peek, duration: TimeInterval = 3.2) {
        if settings.showPet {
            switch peek {
            case .charge: PetState.shared.react(.charge)
            case .audio: PetState.shared.react(.headphones)
            case .screenshot: PetState.shared.react(.surprise)
            case .unlocked: PetState.shared.react(.happy)
            case .claude: PetState.shared.react(.surprise)
            case .capsLock, .hud: break
            }
        }
        guard !model.expanded else { return }
        peekToken += 1
        let token = peekToken
        for slot in slots where !slot.model.expanded && !slot.model.minimal {
            slot.model.peek = peek
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.peekToken == token else { return }
                for slot in self.slots { slot.model.peek = nil }
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
        let s = NotchModel.scale
        let left = f.midX + (-NotchModel.expandedWidth / 2 + 14 + 341) * s
        let top = f.maxY - model.topGap
        guard mouse.x > left, mouse.x < f.midX + NotchModel.expandedWidth / 2 * s,
              mouse.y < top - model.notchSize.height
        else { return event }

        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let horizontal = abs(dx) > abs(dy)
        // Dải ngày + tiêu đề tháng (~78pt dưới hàng tab): cuộn dọc ở đây cũng đổi tuần.
        // Dưới đó là danh sách sự kiện: cuộn dọc để danh sách tự cuộn.
        let inWeekStrip = mouse.y >= top - model.notchSize.height - 78 * s
        if !horizontal && !inWeekStrip { return event }

        // Bỏ quán tính để một lần vuốt chỉ chuyển một tuần.
        if !event.momentumPhase.isEmpty { return nil }
        if event.phase == .began { scrollAccum = 0 }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        scrollAccum += (horizontal ? dx : dy) * scale
        // Vuốt ngang trên trackpad: dải ngày bám theo tay; nhả tay chưa đủ ngưỡng thì bật về.
        let live = horizontal && event.hasPreciseScrollingDeltas
        if event.phase == .ended || event.phase == .cancelled {
            calendar.dragOffset = 0
            return nil
        }

        guard abs(scrollAccum) > 30, Date().timeIntervalSince(lastWeekShift) > 0.35 else {
            if live { calendar.dragOffset = max(-60, min(60, scrollAccum * 0.8)) }
            return nil
        }
        calendar.dragOffset = 0
        calendar.shiftWeek(scrollAccum < 0 ? 1 : -1)
        scrollAccum = 0
        lastWeekShift = Date()
        return nil
    }

    /// Nhịp kiểm chuột khi notch đang mở / đang kéo: 30 Hz là đủ (hover thông minh dùng sự kiện chuột).
    private static let fastPoll: TimeInterval = 1.0 / 30
    /// Rời notch bao lâu thì đóng: đủ ngắn để thấy đóng ngay, đủ dài để rê sát mép không chớp.
    private static let closeGrace: TimeInterval = 0.08
    private static let slowPoll: TimeInterval = 0.1
    private var hoverInterval: TimeInterval = 0

    private func scheduleHover(_ interval: TimeInterval?) {
        guard (interval ?? 0) != hoverInterval else { return }
        hoverInterval = interval ?? 0
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let interval else { return }
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

    /// Cánh lúc thu gọn của slot đang hoạt động (cùng cách tính với NotchRootView).
    private func wingLayout() -> WingLayout {
        WingLayout.resolve(settings: settings, hasTrack: media.hasTrack, calendar: calendar,
                           battery: SystemMonitor.shared.batteryPercent, height: model.notchSize.height)
    }

    private func setExpanded(_ value: Bool) {
        if value, !model.expanded {
            Haptics.tap(.levelChange)
            // "Khi mở notch": tab cố định. Kéo file (khay) và Claude hỏi vẫn được ưu tiên.
            if !fileDragActive, permissions.current == nil, let tab = settings.openTab.tab,
               settings.enabledTabs.contains(tab) {
                model.tab = tab
            }
        }
        model.expanded = value
        if value {
            if model.alert != nil { for slot in slots { slot.model.alert = nil } }
            AlertCenter.shared.notchExpanded()
        } else {
            AlertCenter.shared.notchCollapsed()
        }
        applyMinimal()
        if !value {
            pinned = false
            model.dropTargeted = false
            if !tray.selection.isEmpty { tray.selection = [] }
            // Đợi hiệu ứng đóng chạy xong mới đưa lịch về hôm nay (tránh vẽ lại giữa chừng).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.model.expanded else { return }
                    self.calendar.resetToToday()
                }
            }
        }
        panel.ignoresMouseEvents = !value
    }
}
