import AppKit

/// Hiệu ứng file "bay" vào notch khi thả: ảnh thu nhỏ đi theo đường cong từ chỗ thả tới ô trong khay,
/// nhỏ dần + mờ dần, nhiều file thì lệch nhịp. Chạy bằng Core Animation trong một cửa sổ trong suốt,
/// không nhận chuột, tạo khi thả và gỡ ngay sau ~0.8 s → không tốn gì lúc rảnh.
@MainActor
enum FlyIn {
    static let duration: CFTimeInterval = 0.55
    static let stagger: CFTimeInterval = 0.07
    private static var windows: [NSWindow] = []

    /// `target(i)`: điểm đích (toạ độ màn hình) của file thứ i. `arrive(url)` gọi đúng lúc file đó tới nơi
    /// (Giảm chuyển động: gọi ngay).
    static func run(urls: [URL], from start: NSPoint, on screen: NSScreen,
                    target: @escaping (Int) -> NSPoint, arrive: @escaping (URL) -> Void) {
        guard !urls.isEmpty else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let box = ImageBox()
        // Đợi ảnh xem trước tối đa 0.15 s; không có thì dùng icon Finder.
        let begin = {
            guard !box.started else { return }
            box.started = true
            animate(urls: urls, images: box.images, from: start, screen: screen, target: target, reduce: reduce, arrive: arrive)
        }
        let visual = urls.filter(FileThumbnails.isVisual)
        if visual.isEmpty || reduce {
            begin()
        } else {
            Task { @MainActor in
                for url in visual {
                    if let image = await FileThumbnails.load(url, size: CGSize(width: 72, height: 72)) { box.images[url] = image }
                }
                begin()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { begin() }
        }
    }

    private final class ImageBox {
        var started = false
        var images: [URL: NSImage] = [:]
    }

    private static func animate(urls: [URL], images: [URL: NSImage], from start: NSPoint, screen: NSScreen,
                                target: (Int) -> NSPoint, reduce: Bool, arrive: @escaping (URL) -> Void) {
        let frame = screen.frame
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        window.contentView = host
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        windows.append(window)

        let scale = screen.backingScaleFactor
        let now = CACurrentMediaTime()
        let a = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
        var last: CFTimeInterval = 0
        for (i, url) in urls.prefix(12).enumerated() {
            let image = images[url] ?? NSWorkspace.shared.icon(forFile: url.path)
            let visual = images[url] != nil
            let size = fit(image.size, max: visual ? 64 : 56)
            let layer = CALayer()
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.position = a
            layer.contents = image.layerContents(forContentsScale: scale)
            layer.contentsScale = scale
            layer.contentsGravity = .resizeAspect
            if visual {
                layer.cornerRadius = Theme.isPixel ? 0 : 6
                layer.masksToBounds = true
                layer.borderWidth = Theme.isPixel ? 2 : 1
                layer.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
            }
            layer.opacity = 0
            host.layer?.addSublayer(layer)

            let begin = now + Double(i) * (reduce ? 0 : stagger)
            if reduce {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0
                fade.duration = 0.3
                fade.beginTime = begin
                layer.add(fade, forKey: "fade")
                arrive(url)
                last = max(last, 0.3)
                continue
            }

            let b = target(i)
            let z = CGPoint(x: b.x - frame.minX, y: b.y - frame.minY)
            // Đường cong vồng lên trên rồi rơi vào notch.
            let control = CGPoint(x: (a.x + z.x) / 2 + (z.x - a.x) * 0.15, y: max(a.y, z.y) + 70)
            let path = CGMutablePath()
            path.move(to: a)
            path.addQuadCurve(to: z, control: control)

            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.75, 1)
            let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
            shrink.values = [1.0, 1.1, 0.28]
            shrink.keyTimes = [0, 0.25, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.95, 1, 0.85, 0]
            fade.keyTimes = [0, 0.2, 0.8, 1]
            let group = CAAnimationGroup()
            group.animations = [move, shrink, fade]
            group.duration = duration
            group.beginTime = begin
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "fly")

            let landing = Double(i) * stagger + duration
            last = max(last, landing)
            DispatchQueue.main.asyncAfter(deadline: .now() + landing - 0.05) { arrive(url) }
        }
        // Quá 12 file: phần còn lại vào khay cùng lúc với file cuối.
        for url in urls.dropFirst(12) {
            DispatchQueue.main.asyncAfter(deadline: .now() + last) { arrive(url) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + last + 0.15) {
            window.orderOut(nil)
            window.contentView = nil
            windows.removeAll { $0 === window }
        }
    }

    private static func fit(_ s: CGSize, max m: CGFloat) -> CGSize {
        guard s.width > 0, s.height > 0 else { return CGSize(width: m, height: m) }
        let k = m / Swift.max(s.width, s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}
