import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Điều phối

/// Nhận sự kiện từ PortalServer (đã về main): chạy hiệu ứng, lưu file, ghi clipboard, hỏi ghép đôi.
@MainActor
final class PortalCenter {
    static let shared = PortalCenter()

    /// NotchController gắn: thêm vào khay, notch "nuốt", báo DownloadsWatcher bỏ qua file sắp lưu.
    var addToTray: ((URL) -> Void)?
    var gulp: (() -> Void)?
    var willSave: ((URL) -> Void)?

    private var flights: [UUID: PortalFlight] = [:]

    // MARK: File

    func incoming(id: UUID, name: String, size: Int, from: String) {
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        let flight = PortalFlight(title: name, image: NSWorkspace.shared.icon(for: type))
        flights[id] = flight
        flight.arrive()
    }

    func progress(id: UUID, _ fraction: Double) {
        flights[id]?.setProgress(fraction)
    }

    /// Chuyển file tạm vào thư mục lưu. Trả nil nếu không lưu được.
    func received(id: UUID, temp: URL, name: String) -> URL? {
        let settings = PortalSettings.shared
        let fm = FileManager.default
        let folder = settings.folder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = Self.unique(folder.appendingPathComponent(name))
        willSave?(dest)
        let flight = flights.removeValue(forKey: id)
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)
            flight?.fail()
            return nil
        }
        let toTray = settings.toTray && addToTray != nil
        flight?.complete(url: dest, intoNotch: toTray) { [weak self] in
            if toTray { self?.addToTray?(dest) }
            self?.gulp?()
        }
        return dest
    }

    func failed(id: UUID) {
        flights.removeValue(forKey: id)?.fail()
    }

    /// "ảnh.jpg" đã có thì thành "ảnh 2.jpg", "ảnh 3.jpg"…
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for i in 2...9999 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    // MARK: Clipboard

    func clipboard(id: UUID, data: Data, type: String, from: String) -> Bool {
        guard PortalSettings.shared.acceptClipboard else { return false }
        let pb = NSPasteboard.general
        let title: String
        let image: NSImage
        if type.isEmpty || type.hasPrefix("text/") || type == "application/json" {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return false }
            pb.clearContents()
            pb.setString(text, forType: .string)
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            title = "“" + String(line.prefix(40)) + (line.count > 40 ? "…" : "") + "”"
            image = Self.symbol("doc.on.clipboard")
        } else if type.hasPrefix("image/"), let picture = NSImage(data: data) {
            pb.clearContents()
            pb.writeObjects([picture])
            title = L("Ảnh trong clipboard", "Image on clipboard")
            image = picture
        } else if let uti = UTType(mimeType: type) {
            pb.clearContents()
            pb.setData(data, forType: NSPasteboard.PasteboardType(uti.identifier))
            title = L("Đã chép vào clipboard", "Copied to clipboard")
            image = Self.symbol("doc.on.clipboard")
        } else {
            return false
        }
        let flight = PortalFlight(title: title, image: image)
        flight.arrive()
        flight.complete(url: nil, intoNotch: false, hold: 0.9) {}
        return true
    }

    static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
    }

    // MARK: Ghép đôi

    enum PairResult { case approved(PortalDevice, String), denied, busy }

    private var pairing: PortalPairingPanel?
    private var lastDenied = Date.distantPast

    /// Một yêu cầu một lúc; từ chối xong thì 10 s sau mới hỏi lại (chống spam từ máy lạ trong mạng).
    func askToPair(name: String, code: String?, reply: @escaping (PairResult) -> Void) {
        guard pairing == nil, Date().timeIntervalSince(lastDenied) > 10 else { reply(.busy); return }
        let panel = PortalPairingPanel()
        pairing = panel
        panel.show(name: name, code: code) { [weak self] allowed in
            guard let self else { return }
            self.pairing = nil
            if allowed {
                let (device, token) = PortalSettings.shared.addDevice(name: name, kind: "app")
                reply(.approved(device, token))
            } else {
                self.lastDenied = Date()
                reply(.denied)
            }
        }
    }
}

// MARK: - Hiệu ứng hạ cánh

/// Một "cổng" mở ngay dưới notch của màn hình có con trỏ, thẻ file rơi ra và đáp cạnh con trỏ,
/// lơ lửng trong lúc nhận, xong thì bị hút ngược vào notch (vào khay). Core Animation trong cửa sổ
/// trong suốt không nhận chuột, tạo khi có file và huỷ ngay khi xong.
@MainActor
final class PortalFlight {
    private static var live: [PortalFlight] = []
    static let cardSize = CGSize(width: 124, height: 134)
    private static let trackWidth: CGFloat = 96

    private let window: NSPanel
    private let card = CALayer()
    private let picture = CALayer()
    private let label = CATextLayer()
    private let fill = CALayer()
    private let badge = CALayer()
    private let rift = CAShapeLayer()
    private let palette = Palette.current
    private let mouth: CGPoint
    private let spot: CGPoint
    private let scale: CGFloat
    private let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Lúc thẻ đáp xong (CACurrentMediaTime).
    private var landsAt: CFTimeInterval = 0
    private var ended = false

    init(title: String, image: NSImage) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        scale = screen.backingScaleFactor
        let notch = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        mouth = CGPoint(x: f.width / 2, y: f.height - notch - 6)

        // Đáp cạnh con trỏ (không che con trỏ), nhiều file cùng lúc thì xếp hàng ngang.
        let size = Self.cardSize
        let dir: CGFloat = mouse.x > f.midX ? -1 : 1
        let slot = CGFloat(Self.live.filter { !$0.ended }.count)
        var p = CGPoint(x: mouse.x - f.minX + dir * (size.width / 2 + 28 + slot * (size.width + 14)),
                        y: mouse.y - f.minY - 20)
        let safe = screen.visibleFrame.offsetBy(dx: -f.minX, dy: -f.minY)
            .insetBy(dx: size.width / 2 + 16, dy: size.height / 2 + 16)
        p.x = min(max(p.x, safe.minX), safe.maxX)
        p.y = min(max(p.y, safe.minY), safe.maxY)
        spot = p

        window = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: f.size))
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        window.contentView = host
        window.setFrame(f, display: false)
        build(in: root, title: title, image: image)
        window.orderFrontRegardless()
        Self.live.append(self)
    }

    // MARK: Dựng lớp

    private func build(in root: CALayer, title: String, image: NSImage) {
        let s = Self.cardSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        card.bounds = CGRect(origin: .zero, size: s)
        card.position = spot
        card.backgroundColor = palette.card.cgColor
        card.cornerRadius = palette.radius
        card.borderWidth = palette.borderWidth
        card.borderColor = palette.border.cgColor
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.45
        card.shadowRadius = 14
        card.shadowOffset = CGSize(width: 0, height: -5)
        card.opacity = 0

        picture.frame = CGRect(x: 12, y: 40, width: s.width - 24, height: 82)
        picture.contentsGravity = .resizeAspect
        picture.contentsScale = scale
        picture.contents = image.layerContents(forContentsScale: scale)
        picture.cornerRadius = palette.radius > 0 ? 6 : 0
        picture.masksToBounds = true
        card.addSublayer(picture)

        label.frame = CGRect(x: 8, y: 17, width: s.width - 16, height: 17)
        label.string = title
        label.font = palette.font
        label.fontSize = palette.font.pointSize
        label.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        label.alignmentMode = .center
        label.truncationMode = .middle
        label.contentsScale = scale
        card.addSublayer(label)

        let track = CALayer()
        track.frame = CGRect(x: (s.width - Self.trackWidth) / 2, y: 10, width: Self.trackWidth, height: 3)
        track.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        track.cornerRadius = palette.radius > 0 ? 1.5 : 0
        card.addSublayer(track)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.bounds = CGRect(x: 0, y: 0, width: 0, height: 3)
        fill.position = CGPoint(x: 0, y: 1.5)
        fill.backgroundColor = palette.glow.cgColor
        fill.cornerRadius = track.cornerRadius
        track.addSublayer(fill)

        badge.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        badge.position = CGPoint(x: s.width - 8, y: s.height - 8)
        badge.cornerRadius = palette.radius > 0 ? 13 : 0
        badge.backgroundColor = NSColor(srgbRed: 0.2, green: 0.78, blue: 0.42, alpha: 1).cgColor
        badge.borderWidth = 2
        badge.borderColor = palette.card.cgColor
        let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        badge.contents = check?.layerContents(forContentsScale: scale)
        badge.contentsGravity = .center
        badge.contentsScale = scale
        badge.opacity = 0
        card.addSublayer(badge)
        root.addSublayer(card)

        // Cổng: hình bầu dục đen viền sáng ngay dưới notch (Pixel: hình chữ nhật). Vẽ trên thẻ để thẻ như chui ra.
        let w: CGFloat = 150, h: CGFloat = 16
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        rift.path = Theme.isPixel ? CGPath(rect: rect, transform: nil) : CGPath(ellipseIn: rect, transform: nil)
        rift.position = mouth
        rift.fillColor = NSColor.black.cgColor
        rift.strokeColor = palette.glow.cgColor
        rift.lineWidth = Theme.isPixel ? 3 : 2
        rift.shadowColor = palette.glow.cgColor
        rift.shadowOpacity = 1
        rift.shadowRadius = 12
        rift.shadowOffset = .zero
        rift.opacity = 0
        root.addSublayer(rift)
        CATransaction.commit()
    }

    // MARK: Các pha

    /// Cổng mở, thẻ rơi ra rồi đáp cạnh con trỏ; trong lúc nhận thì lơ lửng nhẹ.
    func arrive() {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = 1
        CATransaction.commit()

        if reduce {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            card.add(fade, forKey: "in")
            landsAt = now + 0.25
            return
        }

        pulseRift(at: now, hold: 0.5)
        let path = CGMutablePath()
        path.move(to: mouth)
        path.addCurve(to: spot, control1: CGPoint(x: mouth.x, y: mouth.y - 150),
                      control2: CGPoint(x: spot.x, y: spot.y + 170))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1)
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [0.12, 0.92, 1.06, 1]
        grow.keyTimes = [0, 0.55, 0.8, 1]
        let tilt: CGFloat = spot.x >= mouth.x ? -0.14 : 0.14
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = [0, tilt, -tilt * 0.35, 0]
        spin.keyTimes = [0, 0.5, 0.82, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1]
        fade.keyTimes = [0, 0.12, 1]
        let group = CAAnimationGroup()
        group.animations = [move, grow, spin, fade]
        group.duration = 0.8
        group.beginTime = now + 0.12
        group.fillMode = .backwards
        card.add(group, forKey: "arrive")
        landsAt = now + 0.92

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.92) { [weak self] in
            guard let self, !self.ended else { return }
            let bob = CABasicAnimation(keyPath: "position.y")
            bob.isAdditive = true
            bob.fromValue = -2.5
            bob.toValue = 2.5
            bob.duration = 1.3
            bob.autoreverses = true
            bob.repeatCount = .greatestFiniteMagnitude
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.card.add(bob, forKey: "bob")
        }
    }

    func setProgress(_ fraction: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        fill.bounds.size.width = Self.trackWidth * CGFloat(min(max(fraction, 0), 1))
        CATransaction.commit()
    }

    /// Nhận xong: dấu tích, đổi sang ảnh xem trước (nếu là ảnh / video), giữ một chút rồi bay về notch.
    func complete(url: URL?, intoNotch: Bool, hold: TimeInterval = 1.1, done: @escaping () -> Void) {
        ended = true
        let wait = max(0, landsAt - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            card.removeAnimation(forKey: "bob")
            setProgress(1)
            if let url, FileThumbnails.isVisual(url) {
                Task { @MainActor in
                    guard let thumb = await FileThumbnails.load(url, size: CGSize(width: 200, height: 164)) else { return }
                    let swap = CATransition()
                    swap.duration = 0.25
                    self.picture.add(swap, forKey: "swap")
                    self.picture.contents = thumb.layerContents(forContentsScale: self.scale)
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badge.opacity = 1
            CATransaction.commit()
            if !reduce {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.2, 1.25, 1]
                pop.keyTimes = [0, 0.6, 1]
                pop.duration = 0.3
                badge.add(pop, forKey: "pop")
                let bump = CAKeyframeAnimation(keyPath: "transform.scale")
                bump.values = [1, 1.06, 1]
                bump.duration = 0.28
                card.add(bump, forKey: "bump")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [self] in
                if intoNotch && !reduce { depart(done) } else { fadeAway(done) }
            }
        }
    }

    func fail() {
        ended = true
        let wait = max(0, landsAt - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            card.removeAnimation(forKey: "bob")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.backgroundColor = NSColor.systemRed.cgColor
            fill.bounds.size.width = Self.trackWidth
            CATransaction.commit()
            if !reduce {
                let shake = CAKeyframeAnimation(keyPath: "position.x")
                shake.isAdditive = true
                shake.values = [0, -9, 9, -6, 6, -2, 0]
                shake.duration = 0.45
                card.add(shake, forKey: "shake")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in fadeAway {} }
        }
    }

    /// Bị hút ngược vào cổng dưới notch.
    private func depart(_ done: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        pulseRift(at: now, hold: 0.42)
        let path = CGMutablePath()
        path.move(to: spot)
        path.addCurve(to: mouth, control1: CGPoint(x: spot.x, y: spot.y + 90),
                      control2: CGPoint(x: mouth.x, y: mouth.y - 120))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.85, 0.6)
        let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
        shrink.values = [1, 1.04, 0.1]
        shrink.keyTimes = [0, 0.2, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.85, 1]
        let group = CAAnimationGroup()
        group.animations = [move, shrink, fade]
        group.duration = 0.6
        group.beginTime = now + 0.1
        group.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = 0
        card.position = mouth
        CATransaction.commit()
        card.add(group, forKey: "depart")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.66) { done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [self] in teardown() }
    }

    private func fadeAway(_ done: @escaping () -> Void) {
        done()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = reduce ? 1 : 0.9
        let group = CAAnimationGroup()
        group.animations = [fade, shrink]
        group.duration = 0.35
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = 0
        CATransaction.commit()
        card.add(group, forKey: "out")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [self] in teardown() }
    }

    /// Cổng mở (0.22 s), giữ `hold`, rồi khép lại.
    private func pulseRift(at begin: CFTimeInterval, hold: Double) {
        let open = 0.22, total = open * 2 + hold
        let times: [NSNumber] = [0, NSNumber(value: open / total), NSNumber(value: (open + hold) / total), 1]
        let sx = CAKeyframeAnimation(keyPath: "transform.scale.x")
        sx.values = [0.05, 1, 1, 0.05]
        sx.keyTimes = times
        let sy = CAKeyframeAnimation(keyPath: "transform.scale.y")
        sy.values = [0.3, 1, 1, 0.3]
        sy.keyTimes = times
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = times
        let group = CAAnimationGroup()
        group.animations = [sx, sy, fade]
        group.duration = total
        group.beginTime = begin
        rift.add(group, forKey: "pulse")
    }

    private func teardown() {
        window.orderOut(nil)
        window.contentView = nil
        Self.live.removeAll { $0 === self }
    }

    // MARK: Màu theo giao diện

    private struct Palette {
        let glow: NSColor
        let card: NSColor
        let border: NSColor
        let borderWidth: CGFloat
        let radius: CGFloat
        let font: NSFont

        static var current: Palette {
            if Theme.isPixel {
                return Palette(glow: NSColor(srgbRed: 1, green: 0.43, blue: 0.66, alpha: 1),
                               card: NSColor(srgbRed: 0.13, green: 0.1, blue: 0.25, alpha: 1),
                               border: NSColor(srgbRed: 0.91, green: 0.88, blue: 1, alpha: 1),
                               borderWidth: 2, radius: 0,
                               font: NSFont(name: "VT323", size: 16) ?? .monospacedSystemFont(ofSize: 11, weight: .regular))
            }
            if Theme.isCassette {
                return Palette(glow: NSColor(srgbRed: 1, green: 0.62, blue: 0.25, alpha: 1),
                               card: NSColor(srgbRed: 0.17, green: 0.14, blue: 0.12, alpha: 1),
                               border: NSColor(srgbRed: 0.95, green: 0.8, blue: 0.6, alpha: 0.5),
                               borderWidth: 1.5, radius: 8,
                               font: .monospacedSystemFont(ofSize: 10.5, weight: .medium))
            }
            if Theme.isVanGogh {
                let base = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
                let serif = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 11.5) } ?? base
                return Palette(glow: NSColor(srgbRed: 0.98, green: 0.83, blue: 0.3, alpha: 1),
                               card: NSColor(srgbRed: 0.1, green: 0.16, blue: 0.36, alpha: 1),
                               border: NSColor(srgbRed: 0.98, green: 0.83, blue: 0.3, alpha: 0.8),
                               borderWidth: 1.5, radius: 14, font: serif)
            }
            return Palette(glow: NSColor(srgbRed: 0.45, green: 0.82, blue: 1, alpha: 1),
                           card: NSColor(white: 0.06, alpha: 0.92),
                           border: NSColor(white: 1, alpha: 0.16),
                           borderWidth: 1, radius: 16,
                           font: .systemFont(ofSize: 11, weight: .medium))
        }
    }
}

// MARK: - Hộp duyệt ghép đôi

/// Thẻ nổi ngay dưới notch: "iPhone của X muốn kết nối", Cho phép / Từ chối. Tự từ chối sau 60 s.
@MainActor
final class PortalPairingPanel {
    private var panel: NSPanel?
    private var decide: ((Bool) -> Void)?

    func show(name: String, code: String?, decide: @escaping (Bool) -> Void) {
        self.decide = decide
        let view = PortalPairingView(name: name, code: code) { [weak self] allowed in self?.finish(allowed) }
        let host = FirstMouseHostingView(rootView: view)
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, NSStatusBar.system.thickness) - 10
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish(false) }
    }

    private func finish(_ allowed: Bool) {
        guard let decide else { return }
        self.decide = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        decide(allowed)
    }
}

private struct PortalPairingView: View {
    let name: String
    let code: String?
    let decide: (Bool) -> Void

    private var radius: CGFloat { Theme.isPixel ? 0 : 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(red: 0.45, green: 0.82, blue: 1))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("“\(name)” muốn kết nối Portal", "“\(name)” wants to connect to Portal"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Cho phép thì thiết bị này gửi được file và clipboard sang máy Mac, lần sau không hỏi lại.",
                           "If you allow it, this device can send files and clipboard to this Mac without asking again."))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let code, !code.isEmpty {
                HStack {
                    Text(L("Mã hiện trên iPhone", "Code shown on the iPhone"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(code).font(.system(size: 20, weight: .bold, design: .monospaced)).tracking(4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: radius / 2).fill(.white.opacity(0.07)))
            }
            HStack(spacing: 10) {
                Spacer()
                pill(L("Từ chối", "Decline"), fill: .white.opacity(0.12)) { decide(false) }
                pill(L("Cho phép", "Allow"), fill: Color(red: 0.2, green: 0.55, blue: 1)) { decide(true) }
            }
        }
        .padding(18)
        .frame(width: 380)
        .foregroundStyle(.white)
        .background(RoundedRectangle(cornerRadius: radius).fill(Color.black.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.12), lineWidth: Theme.isPixel ? 2 : 1))
        .environment(\.colorScheme, .dark)
    }

    private func pill(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.isPixel ? 0 : 99).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
