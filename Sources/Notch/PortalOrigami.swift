import AppKit
import SceneKit

// MARK: - Hiệu ứng gấp giấy

/// File từ iPhone tới dưới dạng máy bay giấy gấp từ chính tấm ảnh: lao ra từ mép phải (đúng độ cao ngón tay hất),
/// lượn, đáp, chờ nhận xong thì mở từng nếp thành tấm ảnh, gấp lại và bay vào notch.
/// SceneKit trong cửa sổ trong suốt không nhận chuột, tạo khi có file, huỷ contentView ngay khi xong.
@MainActor
final class PortalFlight: NSObject {
    private static var live: [PortalFlight] = []

    private let window: NSPanel
    private let view: SCNView
    private let paper: OrigamiPaper
    private let shadow: OrigamiPaper
    private let shadowFlat = SCNNode()
    private let front = SCNMaterial()
    private let glow = CAGradientLayer()
    private let bar = CALayer(), barFill = CALayer()
    private var link: CADisplayLink?
    private let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let w: Double, h: Double
    private let entryY: Double, landX: Double, landY: Double
    private var start = CACurrentMediaTime()
    /// Thời điểm (giây kể từ start) bắt đầu mở giấy; nil = đang chờ nhận xong.
    private var unfoldAt: Double?
    private var hold = 0.6
    private var intoNotch = false
    private var failedAt: Double?
    private var done: (() -> Void)?
    private var finished = false
    /// Chiều ngược (Mac gửi sang iPhone): máy bay cất cánh từ notch, bay ra mép phải.
    private var outbound = false

    static func depart(image: NSImage, url: URL) {
        let f = PortalFlight(title: url.lastPathComponent, image: image, entry: 0.45)
        f.outbound = true
        if FileThumbnails.isVisual(url) {
            Task { @MainActor in
                if let thumb = await FileThumbnails.load(url, size: CGSize(width: 448, height: 336)) {
                    f.front.diffuse.contents = Self.sheet(for: thumb, photo: true)
                }
            }
        }
        f.arrive()
    }

    // Mốc thời gian (giây): lao vào, đáp.
    private let tEnter = 0.10, tTouch = 0.80
    static let paperSize = CGSize(width: 224, height: 168)

    /// entry: độ cao ngón tay lúc rời mép iPhone, 0 = đỉnh, 1 = đáy màn hình.
    init(title: String, image: NSImage, entry: Double? = nil) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        w = f.width; h = f.height
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let frac = min(max(entry ?? 0.45, 0.15), 0.85)
        entryY = h / 2 - frac * h
        // Nhiều file liền nhau: xếp lệch sang trái, xuống dưới để các máy bay không đè lên nhau.
        let slot = CGFloat(Self.live.filter { !$0.finished }.count % 4)
        landX = w / 2 - 260 - slot * 150
        landY = max(-h / 2 + 140, min(h / 2 - topInset - 140, entryY - 40 - slot * 40))

        window = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        view = SCNView(frame: NSRect(origin: .zero, size: f.size), options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.wantsLayer = true
        view.layer?.isOpaque = false

        let back = SCNMaterial()
        back.lightingModel = .physicallyBased
        back.diffuse.contents = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1)
        back.roughness.contents = 0.9
        front.lightingModel = .physicallyBased
        front.roughness.contents = 0.55
        let size = Self.paperSize
        paper = OrigamiPaper(L: size.width, Wd: size.height, keel: 26, nose: 80, front: front, back: back)
        let black = SCNMaterial()
        black.lightingModel = .constant
        black.diffuse.contents = NSColor.black
        black.isDoubleSided = true
        shadow = OrigamiPaper(L: size.width, Wd: size.height, keel: 26, nose: 80, front: black, back: black)
        super.init()
        front.diffuse.contents = Self.sheet(for: image, photo: false)
        view.scene = buildScene(screen: screen)

        let host = NSView(frame: NSRect(origin: .zero, size: f.size))
        host.wantsLayer = true
        host.addSubview(view)
        buildOverlay(in: host.layer!)
        window.contentView = host
        window.setFrame(f, display: false)
        window.orderFrontRegardless()
        Self.live.append(self)
        PortalHover.shared.handOff()
    }

    private func buildScene(screen: NSScreen) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let fov = 28.0
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera!.fieldOfView = fov
        cam.camera!.zNear = 10
        cam.camera!.zFar = 6000
        cam.position = SCNVector3(0, 0, h / 2 / tan(fov / 2 * .pi / 180))   // mặt z = 0 trùng màn hình, đơn vị = point
        scene.rootNode.addChildNode(cam)
        view.pointOfView = cam
        if let url = NSWorkspace.shared.desktopImageURL(for: screen), let wall = NSImage(contentsOf: url) {
            scene.lightingEnvironment.contents = wall
            scene.lightingEnvironment.intensity = 1.1
        }
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 800
        key.position = SCNVector3(0, 0, 800)
        key.look(at: SCNVector3(110, -170, 0))
        scene.rootNode.addChildNode(key)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light!.type = .ambient
        amb.light!.intensity = 220
        scene.rootNode.addChildNode(amb)

        // Bóng: bản sao tờ giấy ép phẳng xuống mặt màn hình theo hướng sáng, tô đen, làm mờ.
        var shear = SCNMatrix4Identity
        shear.m31 = 0.35; shear.m32 = -0.55; shear.m33 = 0.001
        shadowFlat.transform = shear
        shadowFlat.addChildNode(shadow.root)
        shadowFlat.renderingOrder = -1
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(6, forKey: kCIInputRadiusKey)
        shadowFlat.filters = [blur]
        scene.rootNode.addChildNode(shadowFlat)
        scene.rootNode.addChildNode(paper.root)
        return scene
    }

    private func buildOverlay(in root: CALayer) {
        // Khe sáng ở mép phải, đúng độ cao file tới.
        glow.type = .radial
        glow.colors = [NSColor(srgbRed: 0.75, green: 0.92, blue: 1, alpha: 0.75).cgColor,
                       NSColor(srgbRed: 0.35, green: 0.7, blue: 1, alpha: 0.25).cgColor,
                       NSColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0).cgColor]
        glow.locations = [0, 0.35, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: w - 130, y: h / 2 + entryY - 300, width: 260, height: 600)
        glow.opacity = 0
        root.addSublayer(glow)
        // Thanh tiến độ dưới máy bay khi file lớn còn đang nhận.
        bar.frame = CGRect(x: w / 2 + landX - 40, y: h / 2 + landY - 70, width: 80, height: 4)
        bar.cornerRadius = 2
        bar.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        bar.opacity = 0
        barFill.anchorPoint = .zero
        barFill.frame = CGRect(x: 0, y: 0, width: 0, height: 4)
        barFill.cornerRadius = 2
        barFill.backgroundColor = NSColor.white.cgColor
        bar.addSublayer(barFill)
        root.addSublayer(bar)
    }

    // MARK: API cho PortalCenter

    func arrive() {
        guard !reduce else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]
        a.keyTimes = [0, 0.18, 0.45, 1]
        a.duration = 0.9
        glow.add(a, forKey: "flash")
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        tick()
    }

    func setProgress(_ fraction: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        barFill.bounds.size.width = 80 * CGFloat(min(max(fraction, 0), 1))
        CATransaction.commit()
    }

    /// Nhận xong: thay mặt giấy bằng ảnh thật (nếu là ảnh / video), mở giấy, rồi bay vào notch hoặc mờ đi.
    func complete(url: URL?, intoNotch: Bool, hold: TimeInterval = 0.6, done: @escaping () -> Void) {
        self.intoNotch = intoNotch
        self.hold = min(hold, 0.9)
        self.done = done
        if reduce { teardown(); return }
        let go = { [self] in unfoldAt = max(now + 0.05, tTouch + 0.08) }
        if let url, FileThumbnails.isVisual(url) {
            Task { @MainActor in
                if let thumb = await FileThumbnails.load(url, size: CGSize(width: 448, height: 336)) {
                    self.front.diffuse.contents = Self.sheet(for: thumb, photo: true)
                }
                go()
            }
        } else {
            go()
        }
    }

    func fail() {
        if reduce { teardown(); return }
        failedAt = max(now, tTouch)
    }

    // MARK: Khung hình

    private var now: Double { CACurrentMediaTime() - start }

    /// Vài khung đầu vẽ tờ giấy gần như trong suốt ở chỗ xuất hiện để SceneKit biên dịch shader,
    /// xong mới bắt đầu tính giờ (prepare(_:) của SCNView crash với node có filters).
    private var warm = 0

    @objc private func tick() {
        if warm < 4 {
            warm += 1
            var p = pose(tEnter + 0.05)
            p.opacity = 0.01
            apply(p)
            shadowFlat.opacity = 0.01
            start = CACurrentMediaTime()
            return
        }
        let t = now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.opacity = (unfoldAt == nil && failedAt == nil && t > tTouch + 0.3) ? 1 : 0
        CATransaction.commit()
        apply(pose(t))
        if let f = failedAt, t > f + 0.5 { teardown() }
    }

    private struct Pose { var x, y, z, yaw, pitch, roll, scale, opacity: Double; var fold: OrigamiFold }

    private func apply(_ p: Pose) {
        for node in [paper.root, shadow.root] {
            node.position = SCNVector3(p.x, p.y, p.z)
            node.eulerAngles = SCNVector3(p.roll, p.pitch, p.yaw)
            node.scale = SCNVector3(p.scale, p.scale, p.scale)
        }
        paper.apply(p.fold)
        shadow.apply(p.fold)
        paper.root.opacity = p.opacity
        shadowFlat.opacity = 0.4 / (1 + p.z / 140) * p.opacity
        shadowFlat.setValue(3 + p.z * 0.08, forKeyPath: "filters.blur.inputRadius")
    }

    private func glide(_ u: Double) -> (Double, Double, Double) {
        let x = lerp(w / 2 + 170, landX, 1 - pow(1 - u, 1.35))
        let y = entryY + 70 * sin(u * .pi) * (1 - u * 0.3) + (landY - entryY) * u
        return (x, y, lerp(150, 10, pow(u, 1.4)))
    }

    private func launchPath(_ k: Double, from p0: (Double, Double)) -> (Double, Double, Double) {
        let p2 = (0.0, h / 2 - 12), p1 = (lerp(p0.0, p2.0, 0.55), p0.1 + 120)
        let x = pow(1 - k, 2) * p0.0 + 2 * (1 - k) * k * p1.0 + k * k * p2.0
        let y = pow(1 - k, 2) * p0.1 + 2 * (1 - k) * k * p1.1 + k * k * p2.1
        return (x, y, 4 + 170 * sin(k * .pi) * (1 - k * 0.4))
    }

    private func heading(_ dx: Double, _ dy: Double) -> Double {   // mũi máy bay là -x cục bộ
        var a = atan2(dy, dx) - .pi
        if a <= -.pi { a += 2 * .pi }
        return a
    }

    private func fold(_ t: Double) -> OrigamiFold {
        guard let u = unfoldAt else { return .folded }
        let r = u + 0.44 + hold
        var f = OrigamiFold.folded
        func tri(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            OrigamiFold.folded.triL * (1 - easeInOut(seg(t, a, b)) + easeInOut(seg(t, c, d)))
        }
        f.triL = tri(u, u + 0.14, r + 0.14, r + 0.26)
        f.triR = tri(u + 0.05, u + 0.19, r + 0.17, r + 0.28)
        let open = min(1.06, spring(t - (u + 0.16), response: 0.36, damping: 0.62)) * (1 - easeInOut(seg(t, r, r + 0.17)))
        f.keel = OrigamiFold.folded.keel * (1 - open)
        f.wing = OrigamiFold.folded.wing * (1 - open)
        return f
    }

    private func pose(_ t: Double) -> Pose {
        if outbound { return departPose(t) }
        var p = Pose(x: w, y: 0, z: 0, yaw: 0, pitch: 0, roll: 0, scale: 1, opacity: 1, fold: fold(t))
        guard t >= tEnter else { return p }
        if t < tTouch {
            let u = seg(t, tEnter, tTouch)
            let a = glide(u), b = glide(min(1, u + 0.01))
            p.x = a.0; p.y = a.1; p.z = a.2
            p.yaw = max(-0.55, min(0.55, heading(b.0 - a.0, b.1 - a.1)))
            p.roll = 34 * .pi / 180 * sin(u * .pi * 1.6) * (1 - u)                                    // nghiêng cánh khi lượn
            p.pitch = (5 * sin(u * .pi * 3) * (1 - u) - 16 * sin(seg(u, 0.82, 1) * .pi)) * .pi / 180   // ngóc mũi trước khi đáp
            return p
        }
        let end = glide(1), pre = glide(0.99)
        let yaw0 = max(-0.55, min(0.55, heading(end.0 - pre.0, end.1 - pre.1)))
        let skid = easeOut3(seg(t, tTouch, tTouch + 0.12))
        p.x = end.0 - 16 * skid; p.y = end.1 + 3 * skid; p.z = lerp(10, 3, skid)
        p.yaw = yaw0
        if let f = failedAt {   // hỏng: máy bay xẹp xuống rồi mờ đi
            let k = seg(t, f, f + 0.45)
            p.opacity = 1 - k; p.z = lerp(p.z, 0, k); p.roll = 0.5 * k
            return p
        }
        guard let u = unfoldAt else {   // chờ nhận xong: phập phồng nhẹ
            let idle = t - tTouch - 0.12
            if idle > 0 { p.z += 3 * (1 - cos(idle * 3)); p.roll = 0.04 * sin(idle * 2.4) }
            return p
        }
        let flat = u + 0.44, r = flat + hold, l0 = r + 0.28, l1 = l0 + 0.52
        let o = seg(t, u + 0.14, flat)
        p.z += 30 * sin(o * .pi)
        p.yaw = lerp(yaw0, -5 * .pi / 180, easeInOut(seg(t, u - 0.05, flat)))
        p.pitch = -6 * .pi / 180 * sin(o * .pi)
        if !intoNotch {   // clipboard: mở ra cho xem rồi mờ đi
            let k = seg(t, r, r + 0.35)
            p.opacity = 1 - k
            if t >= r { fire() }
            if k >= 1 { DispatchQueue.main.async { self.teardown() } }
            return p
        }
        let launch0 = (p.x, p.y)
        let first = launchPath(0.02, from: launch0)
        p.yaw = lerp(p.yaw, heading(first.0 - launch0.0, first.1 - launch0.1), easeInOut(seg(t, r, l0)))
        p.z += 14 * sin(seg(t, r, l0) * .pi)
        if t >= l0 {
            let v = seg(t, l0, l1)
            let k = easeInOut(v) * 0.75 + v * 0.25
            let a = launchPath(k, from: launch0), b = launchPath(min(1, k + 0.01), from: launch0)
            p.x = a.0; p.y = a.1; p.z = a.2
            p.yaw = heading(b.0 - a.0, b.1 - a.1)
            p.pitch = -12 * sin(v * .pi) * .pi / 180
            p.roll = 18 * .pi / 180 * sin(v * .pi * 1.3)
            p.scale = lerp(1, 0.2, pow(k, 1.3))
            p.opacity = v < 0.985 ? 1 : 0
            if v > 0.93 { fire() }
            if t > l1 + 0.1 { DispatchQueue.main.async { self.teardown() } }
        }
        return p
    }

    /// Cất cánh từ notch, lượn xuống rồi lao ra mép phải ở độ cao giữa màn hình.
    private func departPose(_ t: Double) -> Pose {
        let u = min(1, t / 1.1)
        let k = easeInOut(u)
        let p0 = (0.0, h / 2 - 12), p2 = (w / 2 + 220, entryY), p1 = (w * 0.18, h / 2 - 80)
        func at(_ k: Double) -> (Double, Double) {
            (pow(1 - k, 2) * p0.0 + 2 * (1 - k) * k * p1.0 + k * k * p2.0, pow(1 - k, 2) * p0.1 + 2 * (1 - k) * k * p1.1 + k * k * p2.1)
        }
        let a = at(k), b = at(min(1, k + 0.01))
        var p = Pose(x: a.0, y: a.1, z: 20 + 140 * sin(k * .pi), yaw: heading(b.0 - a.0, b.1 - a.1), pitch: 0,
                     roll: 0.4 * sin(u * .pi * 1.5), scale: lerp(0.2, 1, min(1, k * 1.6)), opacity: 1, fold: .folded)
        if t > 1.15 { p.opacity = 0; DispatchQueue.main.async { self.teardown() } }
        return p
    }

    private func fire() {
        guard let d = done else { return }
        done = nil
        d()
    }

    private func teardown() {
        guard !finished else { return }
        finished = true
        fire()
        link?.invalidate()
        link = nil
        view.scene = nil
        window.orderOut(nil)
        window.contentView = nil
        Self.live.removeAll { $0 === self }
    }

    /// Mặt trước tờ giấy 4:3. Ảnh thật thì lấp đầy; icon thì nằm giữa tờ giấy trắng.
    private static func sheet(for image: NSImage, photo: Bool) -> NSImage {
        let s = CGSize(width: 448, height: 336)
        return NSImage(size: s, flipped: false) { r in
            NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
            r.fill()
            let i = image.size
            guard i.width > 0, i.height > 0 else { return true }
            let k = photo ? max(s.width / i.width, s.height / i.height) : min(150 / i.width, 150 / i.height)
            let d = CGSize(width: i.width * k, height: i.height * k)
            image.draw(in: CGRect(x: (s.width - d.width) / 2, y: (s.height - d.height) / 2, width: d.width, height: d.height))
            return true
        }
    }
}

// MARK: - Báo trước khi file tới

/// Lúc ngón tay trên iPhone kéo ảnh lại gần mép trái: mép phải màn hình Mac sáng lên đúng độ cao đó,
/// mạnh dần theo độ gần, và mũi tờ giấy ló ra khỏi viền. Khi file thật tới thì nhường cho PortalFlight.
/// Cửa sổ hẹp ở mép phải, tạo khi có tín hiệu, huỷ sau khi tắt (hoặc 1,5 s không có tín hiệu mới).
@MainActor
final class PortalHover {
    static let shared = PortalHover()

    private var window: NSPanel?
    private let glow = CAGradientLayer()
    private let tip = CAShapeLayer()
    private var screenHeight: CGFloat = 0
    private var stamp = 0
    private static let width: CGFloat = 260

    /// phase: begin / move / fling / cancel. near: 0..1 (1 = ngón tay sát mép). y: 0 = đỉnh, 1 = đáy.
    func update(y: Double, near: Double, phase: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if phase == "cancel" { hide(after: 0); return }
        if window == nil { show() }
        let n = CGFloat(min(max(near, 0), 1))
        let cy = screenHeight * CGFloat(1 - min(max(y, 0.05), 0.95))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        glow.position = CGPoint(x: Self.width, y: cy)
        glow.opacity = Float(0.25 + 0.75 * n)
        glow.transform = CATransform3DMakeScale(0.7 + 0.5 * n, 0.7 + 0.5 * n, 1)
        tip.position = CGPoint(x: Self.width + 6 - 64 * n * n, y: cy)   // máy bay giấy ló ra khi rất gần
        tip.opacity = n > 0.35 ? 1 : 0
        CATransaction.commit()
        // fling: file sắp tới, PortalFlight sẽ gọi handOff; phòng khi không tới thì tự tắt.
        hide(after: phase == "fling" ? 1.2 : 1.5)
    }

    /// File thật đã tới: tắt nhanh để máy bay giấy thế chỗ.
    func handOff() { hide(after: 0, fade: 0.18) }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        screenHeight = f.height
        let frame = NSRect(x: f.maxX - Self.width, y: f.minY, width: Self.width, height: f.height)
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        let root = host.layer!

        glow.type = .radial
        glow.colors = [NSColor(srgbRed: 0.75, green: 0.92, blue: 1, alpha: 0.8).cgColor,
                       NSColor(srgbRed: 0.35, green: 0.7, blue: 1, alpha: 0.28).cgColor,
                       NSColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0).cgColor]
        glow.locations = [0, 0.35, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.bounds = CGRect(x: 0, y: 0, width: 300, height: 640)
        glow.opacity = 0
        root.addSublayer(glow)

        // Máy bay giấy kiểu cổ điển (cùng hình icon app), mũi chỉ sang trái, ló ra từ viền phải.
        // Toạ độ chuẩn hoá (mũi ở phải trên) lật ngang, y lật vì CALayer gốc ở dưới.
        let W: CGFloat = 84, H: CGFloat = 84
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (1 - x) * W, y: (1 - y) * H) }
        let top = CGMutablePath()
        top.addLines(between: [pt(1, 0), pt(0, 0.44), pt(0.38, 0.6)]); top.closeSubpath()
        let flap = CGMutablePath()
        flap.addLines(between: [pt(0, 0.44), pt(0.38, 0.6), pt(0.3, 0.66)]); flap.closeSubpath()
        let under = CGMutablePath()
        under.addLines(between: [pt(1, 0), pt(0.45, 0.64), pt(0.6, 1)]); under.closeSubpath()
        tip.path = top
        tip.fillColor = NSColor.white.cgColor
        tip.shadowColor = NSColor.black.cgColor
        tip.shadowOpacity = 0.35
        tip.shadowRadius = 8
        tip.shadowOffset = CGSize(width: 6, height: -10)
        tip.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        tip.anchorPoint = CGPoint(x: 0, y: 0.5)
        tip.opacity = 0
        for (path, color) in [(flap, NSColor(srgbRed: 0.7, green: 0.65, blue: 0.82, alpha: 1)),
                              (under, NSColor(srgbRed: 0.84, green: 0.8, blue: 0.92, alpha: 1))] {
            let face = CAShapeLayer()
            face.path = path
            face.fillColor = color.cgColor
            tip.addSublayer(face)
        }
        root.addSublayer(tip)

        w.contentView = host
        w.orderFrontRegardless()
        window = w
    }

    private func hide(after delay: Double, fade: Double = 0.3) {
        stamp += 1
        let mine = stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.stamp == mine, let w = self.window else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(fade)
            self.glow.opacity = 0
            self.tip.opacity = 0
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.05) {
                guard self.stamp == mine, self.window === w else { return }
                w.orderOut(nil)
                w.contentView = nil
                self.window = nil
            }
        }
    }
}

// MARK: - Tờ giấy gấp được

/// Góc gấp (radian). Tất cả bằng 0 là tờ giấy phẳng.
struct OrigamiFold {
    var keel, wing, triL, triR: Double
    static let folded = OrigamiFold(keel: 78 * .pi / 180, wing: 70 * .pi / 180, triL: 178 * .pi / 180, triR: 178 * .pi / 180)
}

/// Một tờ giấy (mặt trước in ảnh) chia thành các mặt nối bản lề, gấp cứng thành máy bay phi tiêu và mở lại.
/// Trục x dọc thân (mũi ở -L/2), y ngang. keel: nửa bề rộng sống thân, nose: chiều dài tam giác mũi gấp vào.
final class OrigamiPaper {
    let root = SCNNode()
    private let keelL = SCNNode(), keelR = SCNNode(), wingL = SCNNode(), wingR = SCNNode(), triL = SCNNode(), triR = SCNNode()
    private let axisL: SCNVector3, axisR: SCNVector3

    init(L: CGFloat, Wd: CGFloat, keel k: CGFloat, nose n: CGFloat, front: SCNMaterial, back: SCNMaterial) {
        let hw = Wd / 2, x0 = -L / 2, x1 = L / 2
        func panel(_ pts: [CGPoint], hinge h: CGPoint) -> SCNGeometry {
            var v: [SCNVector3] = [], nf: [SCNVector3] = [], uv: [CGPoint] = []
            for z in [CGFloat(1), -1] {
                for p in pts {
                    v.append(SCNVector3(p.x - h.x, p.y - h.y, 0))
                    nf.append(SCNVector3(0, 0, z))
                    uv.append(CGPoint(x: (p.x - x0) / L, y: (hw - p.y) / Wd))
                }
            }
            let c = Int32(pts.count)
            var fi: [Int32] = [], bi: [Int32] = []
            for i in 1..<(c - 1) { fi += [0, i, i + 1]; bi += [c, c + i + 1, c + i] }   // mặt sau đảo chiều
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: nf), SCNGeometrySource(textureCoordinates: uv)],
                                elements: [SCNGeometryElement(indices: fi, primitiveType: .triangles),
                                           SCNGeometryElement(indices: bi, primitiveType: .triangles)])
            g.materials = [front, back]
            return g
        }
        let P = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }
        keelL.geometry = panel([P(x0, 0), P(x1, 0), P(x1, k), P(x0, k)], hinge: P(0, 0))
        keelR.geometry = panel([P(x0, -k), P(x1, -k), P(x1, 0), P(x0, 0)], hinge: P(0, 0))
        wingL.geometry = panel([P(x0, k), P(x1, k), P(x1, hw), P(x0 + n, hw)], hinge: P(0, k))
        wingR.geometry = panel([P(x0, -k), P(x0 + n, -hw), P(x1, -hw), P(x1, -k)], hinge: P(0, -k))
        triL.geometry = panel([P(x0, k), P(x0 + n, hw), P(x0, hw)], hinge: P(x0, k))
        triR.geometry = panel([P(x0, -k), P(x0, -hw), P(x0 + n, -hw)], hinge: P(x0, -k))
        wingL.position = SCNVector3(0, k, 0)
        wingR.position = SCNVector3(0, -k, 0)
        triL.position = SCNVector3(x0, 0, 0)
        triR.position = SCNVector3(x0, 0, 0)
        let al = simd_normalize(SIMD3<Float>(Float(n), Float(hw - k), 0)), ar = simd_normalize(SIMD3<Float>(Float(n), -Float(hw - k), 0))
        axisL = SCNVector3(al.x, al.y, 0)
        axisR = SCNVector3(ar.x, ar.y, 0)
        root.addChildNode(keelL)
        root.addChildNode(keelR)
        keelL.addChildNode(wingL)
        keelR.addChildNode(wingR)
        wingL.addChildNode(triL)
        wingR.addChildNode(triR)
    }

    func apply(_ f: OrigamiFold) {
        keelL.rotation = SCNVector4(1, 0, 0, f.keel)
        keelR.rotation = SCNVector4(1, 0, 0, -f.keel)
        wingL.rotation = SCNVector4(1, 0, 0, -f.wing)
        wingR.rotation = SCNVector4(1, 0, 0, f.wing)
        triL.rotation = SCNVector4(axisL.x, axisL.y, axisL.z, -f.triL)   // âm: gập xuống dưới cánh
        triR.rotation = SCNVector4(axisR.x, axisR.y, axisR.z, f.triR)
    }
}

// MARK: - Đường cong thời gian

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
private func easeOut3(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
/// Lò xo tắt dần 0 → 1 (có vọt).
private func spring(_ t: Double, response: Double, damping: Double) -> Double {
    if t <= 0 { return 0 }
    let w = 2 * Double.pi / response, wd = w * sqrt(1 - damping * damping)
    return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
}
