import AppKit
import SwiftUI

/// Thú cưng trên notch: mỗi theme một nhân vật (mèo pixel, cuộn băng vẽ tay, bóng ma).
/// Hoạt ảnh do Core Animation chạy ở render server: app không phải thức dậy để vẽ từng khung.
enum PetMood: Equatable {
    case idle    // ngồi chơi: chớp mắt, vẫy đuôi / lơ lửng
    case dance   // đang có nhạc
    case sleep   // máy rảnh lâu
    case alert   // Claude xin quyền (notch mở → hiện trên hàng tab)
}

/// Phản ứng một lần theo sự kiện hoặc tự làm trò lúc rảnh.
enum PetReaction {
    case heart, happy, charge, surprise, headphones, yawn, stretch, lookAround, special
}

struct PetEvent: Equatable {
    let kind: PetReaction
    let token: Int
}

@MainActor
final class PetState: ObservableObject {
    static let shared = PetState()
    @Published var mood: PetMood = .idle
    /// Hướng nhìn theo con trỏ: -1 (trái) … 1 (phải), làm tròn 0.5 để ít cập nhật.
    @Published private(set) var look: CGFloat = 0
    @Published private(set) var event: PetEvent?
    private var token = 0
    private var idleTimer: Timer?

    func react(_ kind: PetReaction) {
        token += 1
        event = PetEvent(kind: kind, token: token)
    }

    func setLook(_ value: CGFloat) {
        let bucket = (min(max(value, -1), 1) * 2).rounded() / 2
        if bucket != look { look = bucket }
    }

    /// Mỗi 20–40s (khi đang ngồi chơi) tự làm một trò.
    func startIdleActions() {
        idleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: .random(in: 20...40), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mood == .idle {
                    self.react([.yawn, .stretch, .lookAround, .special, .special].randomElement()!)
                }
                self.startIdleActions()
            }
        }
        timer.tolerance = 3
        idleTimer = timer
    }
}

// MARK: - View

struct PetView: View {
    @ObservedObject private var pet = PetState.shared

    var body: some View {
        PetLayer(mood: pet.mood, look: pet.look, event: pet.event)
            .contentShape(Rectangle())
            .onTapGesture { pet.react(.heart) }
            .help(L("Vuốt ve", "Pet me"))
    }
}

private struct PetLayer: NSViewRepresentable {
    let mood: PetMood
    let look: CGFloat
    let event: PetEvent?

    func makeNSView(context: Context) -> PetLayerView { PetLayerView(lastToken: event?.token ?? 0) }
    func updateNSView(_ view: PetLayerView, context: Context) { view.update(mood: mood, look: look, event: event) }
}

final class PetLayerView: NSView {
    private let character: PetBase
    private let holder = CALayer()
    private let bubble = CATextLayer()
    private var mood: PetMood = .idle
    private var applied = false
    private var lookX: CGFloat = 0
    private var lastToken: Int
    private var reaction = 0

    init(lastToken: Int) {
        self.lastToken = lastToken
        switch Theme.current {
        case .pixel: character = PixelDino()
        case .cassette: character = Walkman()
        case .standard: character = Fox()
        }
        super.init(frame: .zero)
        wantsLayer = true
        holder.bounds = character.root.bounds
        holder.anchorPoint = CGPoint(x: 0.5, y: 0)
        character.root.anchorPoint = CGPoint(x: 0.5, y: 0)
        character.root.position = CGPoint(x: holder.bounds.midX, y: 0)
        holder.addSublayer(character.root)
        layer?.addSublayer(holder)

        let font: NSFont = switch Theme.current {
        case .pixel: NSFont(name: "VT323", size: 14) ?? .monospacedSystemFont(ofSize: 9, weight: .heavy)
        case .cassette: NSFont(name: "Marker Felt", size: 11) ?? .systemFont(ofSize: 10)
        case .standard: .systemFont(ofSize: 9, weight: .heavy)
        }
        bubble.font = font
        bubble.fontSize = font.pointSize
        bubble.alignmentMode = .center
        bubble.contentsScale = 2
        bubble.bounds = CGRect(x: 0, y: 0, width: 30, height: 14)
        layer?.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Notch thấp (màn rời ~24pt) thì thu nhỏ nhân vật cho vừa.
        let scale = min(1, (bounds.height - 3) / holder.bounds.height)
        holder.transform = CATransform3DMakeScale(scale, scale, 1)
        holder.position = CGPoint(x: bounds.midX - 3, y: 1)
        bubble.position = CGPoint(x: bounds.midX + 13, y: bounds.maxY - 7)
        CATransaction.commit()
    }

    func update(mood: PetMood, look: CGFloat, event: PetEvent?) {
        self.mood = mood
        lookX = look
        if reaction == 0 {
            if !applied || character.mood != mood {
                applied = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                character.apply(mood)
                character.look(look)
                moodBubble()
                CATransaction.commit()
            } else {
                character.look(look)
            }
        }
        if let event, event.token != lastToken {
            lastToken = event.token
            perform(event.kind)
        }
    }

    private func perform(_ kind: PetReaction) {
        reaction += 1
        let id = reaction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let (duration, text, color) = character.react(kind)
        bubble.removeAllAnimations()
        bubble.string = text
        bubble.opacity = 1
        bubble.foregroundColor = (color ?? character.ink).cgColor
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.reaction == id else { return }
            self.reaction = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.character.apply(self.mood)
            self.character.look(self.lookX)
            self.moodBubble()
            CATransaction.commit()
        }
    }

    private func moodBubble() {
        bubble.removeAllAnimations()
        bubble.opacity = 1
        bubble.foregroundColor = (mood == .alert ? NSColor.systemYellow : character.ink).cgColor
        switch mood {
        case .idle:
            bubble.string = nil
        case .dance:
            bubble.string = "♪"
            bubble.add(loop("opacity", [1, 0.35], times: [0, 0.5], duration: 0.84), forKey: "note")
        case .sleep:
            bubble.string = "z"
            bubble.add(loop("opacity", [0, 0.5, 1, 0], times: [0, 0.25, 0.5, 0.85], duration: 2.4), forKey: "z")
        case .alert:
            bubble.string = "!"
        }
    }
}

// MARK: - Animation helpers

/// Keyframe lặp vô hạn. Mặc định nhảy khung rời (render server chỉ vẽ lại vài lần/giây);
/// `smooth` nội suy mượt với khung hình giới hạn `fps`.
func loop(_ keyPath: String, _ values: [Any], times: [Double], duration: CFTimeInterval,
          smooth: Bool = false, fps: Float = 30) -> CAKeyframeAnimation {
    let anim = keyframes(keyPath, values, times: times, duration: duration, smooth: smooth, fps: fps)
    anim.repeatCount = .infinity
    return anim
}

/// Keyframe chạy một lần (phản ứng).
func once(_ keyPath: String, _ values: [Any], times: [Double], duration: CFTimeInterval) -> CAKeyframeAnimation {
    keyframes(keyPath, values, times: times, duration: duration, smooth: true, fps: 30)
}

private func keyframes(_ keyPath: String, _ values: [Any], times: [Double], duration: CFTimeInterval,
                       smooth: Bool, fps: Float) -> CAKeyframeAnimation {
    let anim = CAKeyframeAnimation(keyPath: keyPath)
    anim.values = values
    anim.keyTimes = times.map { NSNumber(value: $0) }
    anim.duration = duration
    anim.isRemovedOnCompletion = true
    if smooth {
        anim.calculationMode = .linear
        anim.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(values.count - 1, 1))
        anim.preferredFrameRateRange = CAFrameRateRange(minimum: min(8, fps), maximum: fps, preferred: fps)
    } else {
        anim.calculationMode = .discrete
    }
    return anim
}

private func shape(_ path: CGPath, fill: NSColor?, stroke: NSColor? = nil, width: CGFloat = 1) -> CAShapeLayer {
    let l = CAShapeLayer()
    l.path = path
    l.fillColor = fill?.cgColor
    l.strokeColor = stroke?.cgColor
    l.lineWidth = width
    l.lineCap = .round
    l.lineJoin = .round
    l.contentsScale = 2
    return l
}

/// Lớp có tâm tại `center`, path vẽ quanh gốc (0,0) → scale / dời quanh tâm.
private func centered(_ sub: CAShapeLayer, at center: CGPoint, size: CGFloat) -> CAShapeLayer {
    sub.bounds = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    sub.position = center
    return sub
}

private func arc(_ w: CGFloat, _ h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -w / 2, y: 0))
    p.addQuadCurve(to: CGPoint(x: w / 2, y: 0), control: CGPoint(x: 0, y: h))
    return p
}

// MARK: - Khung chung

/// Toạ độ y hướng xuống (root lật hình học). `actor` nhận phản ứng, `root` nhận hoạt ảnh theo mood.
@MainActor
class PetBase {
    enum Eyes { case open, closed, happy, wide }

    let root = CALayer()
    let actor = CALayer()
    private let headphones = CALayer()
    var eyes: Eyes = .open
    var mouthOpen = false
    var lookX: CGFloat = 0
    private(set) var mood: PetMood = .idle
    var ink: NSColor { .white }

    /// `head` = vùng đầu để đeo tai nghe khi kết nối AirPods (nil = nhân vật tự có tai nghe).
    init(size: CGSize, head: CGRect?, pixel: Bool) {
        root.bounds = CGRect(origin: .zero, size: size)
        root.isGeometryFlipped = true
        actor.frame = root.bounds
        root.addSublayer(actor)
        headphones.frame = root.bounds
        headphones.zPosition = 10
        headphones.isHidden = true
        actor.addSublayer(headphones)
        guard let head else { return }
        let band = CGMutablePath()
        if pixel {
            band.addLines(between: [CGPoint(x: head.minX - 1, y: head.midY), CGPoint(x: head.minX - 1, y: head.minY),
                                    CGPoint(x: head.maxX + 1, y: head.minY), CGPoint(x: head.maxX + 1, y: head.midY)])
        } else {
            band.move(to: CGPoint(x: head.minX - 0.5, y: head.midY))
            band.addCurve(to: CGPoint(x: head.maxX + 0.5, y: head.midY),
                          control1: CGPoint(x: head.minX - 1, y: head.minY - 4), control2: CGPoint(x: head.maxX + 1, y: head.minY - 4))
        }
        headphones.addSublayer(shape(band, fill: nil, stroke: NSColor(white: 0.25, alpha: 1), width: pixel ? 1.5 : 1.6))
        let cup = NSColor(red: 1, green: 0.36, blue: 0.45, alpha: 1)
        for x in [head.minX - 2.5, head.maxX - 1] {
            let r = CGRect(x: x, y: head.midY - 2.5, width: 3.5, height: 5.5)
            headphones.addSublayer(shape(pixel ? CGPath(rect: r, transform: nil)
                                               : CGPath(roundedRect: r, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil),
                                         fill: cup))
        }
    }

    // Lớp con ghi đè.
    func render() {}
    func moodAnimations(_ mood: PetMood) {}
    func clearParts() {}
    func special() -> (CFTimeInterval, String?) { (0.5, nil) }

    func apply(_ mood: PetMood) {
        self.mood = mood
        root.removeAllAnimations()
        actor.removeAllAnimations()
        clearParts()
        root.transform = CATransform3DIdentity
        actor.transform = CATransform3DIdentity
        actor.opacity = 1
        headphones.isHidden = true
        eyes = mood == .sleep ? .closed : mood == .alert ? .wide : .open
        mouthOpen = mood == .alert
        render()
        moodAnimations(mood)
    }

    func look(_ x: CGFloat) {
        guard x != lookX else { return }
        lookX = x
        render()
    }

    /// Trả về (thời lượng, chữ bong bóng, màu chữ).
    func react(_ kind: PetReaction) -> (CFTimeInterval, String?, NSColor?) {
        actor.removeAllAnimations()
        root.removeAllAnimations()
        clearParts()
        switch kind {
        case .heart:
            eyes = .happy; mouthOpen = false; render()
            hop(4, count: 2, period: 0.36)
            return (1.5, "♥", NSColor(red: 1, green: 0.42, blue: 0.62, alpha: 1))
        case .happy:
            eyes = .happy; render()
            hop(3, count: 2, period: 0.3)
            return (1.0, "♪", nil)
        case .charge:
            eyes = .wide; render()
            hop(4, count: 1, period: 0.4)
            return (1.5, "⚡", .systemYellow)
        case .surprise:
            eyes = .wide; mouthOpen = true; render()
            hop(5, count: 1, period: 0.35)
            return (1.3, "!", .systemYellow)
        case .headphones:
            headphones.isHidden = false
            eyes = .happy; render()
            actor.add(once("transform.rotation.z", [0, -0.12, 0.12, -0.12, 0.12, 0], times: [0, 0.2, 0.4, 0.6, 0.8, 1], duration: 3.6), forKey: "groove")
            return (4, "♫", nil)
        case .yawn:
            eyes = .closed; mouthOpen = true; render()
            stretch(1.8)
            return (1.9, nil, nil)
        case .stretch:
            stretch(1.3)
            return (1.4, nil, nil)
        case .lookAround:
            look(-1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.look(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.look(0) }
            return (2.3, "?", nil)
        case .special:
            let (d, text) = special()
            return (d, text, nil)
        }
    }

    /// Nhảy lên (y hướng xuống nên âm = lên).
    func hop(_ amp: CGFloat, count: Int, period: CFTimeInterval) {
        var values: [CGFloat] = [0]
        var times: [Double] = [0]
        for i in 0..<count {
            values += [-amp, 0]
            times += [(Double(i) + 0.45) / Double(count), Double(i + 1) / Double(count)]
        }
        actor.add(once("transform.translation.y", values, times: times, duration: period * Double(count)), forKey: "hop")
    }

    private func stretch(_ duration: CFTimeInterval) {
        let values = [CATransform3DIdentity, CATransform3DMakeScale(0.9, 1.12, 1), CATransform3DMakeScale(1.08, 0.94, 1), CATransform3DIdentity]
        actor.add(once("transform", values.map { NSValue(caTransform3D: $0) }, times: [0, 0.4, 0.75, 1], duration: duration), forKey: "stretch")
    }
}

// MARK: - Pixel: khủng long 8-bit (20×19, mỗi ô = 1pt)

private enum DinoSprite {
    static let width = 20, height = 19

    private static let base: [String] = [
        ".......s............",
        "......sss.s.........",
        "....gggggggggs......",
        "...gggggggggggs.....",
        "...gggggggggggs.....",
        "..gggggggggggggs....",
        "..gggggggggggggs....",
        "..gggggggggggggds...",
        "...gggggggggggds....",
        "....ggggggggggds....",
        "...gglllllllggdss...",
        "..ggllllllllgggd..gs",
        "..dgllllllllllggdggs",
        "..dglllllllllllggg..",
        "...glllllllllgggd...",
        "...ggllllllllggd....",
        "....ggggggggggd.....",
        "....ggd....ggd......",
        "...dddd...dddd......",
    ]

    static func grid(eyes: PetBase.Eyes, look: Int, mouthOpen: Bool, tail: Int) -> [[Character]] {
        var g = base.map { Array($0) }
        func put(_ r: Int, _ c: Int, _ ch: Character) {
            if (0..<height).contains(r), (0..<width).contains(c) { g[r][c] = ch }
        }
        if tail == 1 {   // đuôi vểnh xuống
            put(11, 18, "."); put(12, 18, "g"); put(12, 19, "."); put(13, 18, "g"); put(13, 19, "s"); put(11, 17, "g")
        }
        let left = 5 + look, right = 10 + look
        switch eyes {
        case .open:
            for c in [left, right] { put(4, c, "w"); put(4, c + 1, "e"); put(5, c, "e"); put(5, c + 1, "e") }
        case .closed:
            for c in [left, right] { put(5, c, "e"); put(5, c + 1, "e") }
        case .happy:
            put(5, left, "e"); put(4, left + 1, "e"); put(5, left + 2, "e")
            put(5, right - 1, "e"); put(4, right, "e"); put(5, right + 1, "e")
        case .wide:
            for c in [left, right] {
                for r in 3...5 { put(r, c, "e"); put(r, c + 1, "e") }
                put(3, c, "w")
            }
        }
        put(6, 4, "p"); put(6, 12, "p")   // má hồng
        if mouthOpen {
            for c in 6...10 { put(7, c, "e") }
            put(8, 6, "e"); put(8, 7, "p"); put(8, 8, "p"); put(8, 9, "p"); put(8, 10, "e")
        } else {
            put(7, 6, "e"); put(8, 7, "e"); put(8, 8, "e"); put(8, 9, "e"); put(7, 10, "e")
        }
        return g
    }

    private static var cache: [String: CGImage] = [:]

    static func image(eyes: PetBase.Eyes, look: Int, mouthOpen: Bool, tail: Int) -> CGImage? {
        let key = "\(eyes)|\(look)|\(mouthOpen)|\(tail)"
        if let hit = cache[key] { return hit }
        let g = grid(eyes: eyes, look: look, mouthOpen: mouthOpen, tail: tail)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors: [Character: NSColor] = [
            "g": NSColor(red: 0.46, green: 0.81, blue: 0.38, alpha: 1),
            "d": NSColor(red: 0.23, green: 0.5, blue: 0.27, alpha: 1),
            "l": NSColor(red: 0.89, green: 0.94, blue: 0.66, alpha: 1),
            "s": NSColor(red: 1, green: 0.69, blue: 0.25, alpha: 1),
            "e": NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1),
            "w": .white,
            "p": NSColor(red: 1, green: 0.5, blue: 0.59, alpha: 1),
        ]
        for r in 0..<height {
            for c in 0..<width {
                guard let color = colors[g[r][c]] else { continue }
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: c, y: height - 1 - r, width: 1, height: 1))
            }
        }
        let image = ctx.makeImage()
        cache[key] = image
        return image
    }
}

final class PixelDino: PetBase {
    private let sprite = CALayer()
    override var ink: NSColor { NSColor(red: 0.62, green: 0.9, blue: 0.5, alpha: 1) }

    init() {
        super.init(size: CGSize(width: 20, height: 19), head: CGRect(x: 3, y: 2, width: 11, height: 7), pixel: true)
        sprite.frame = actor.bounds
        sprite.magnificationFilter = .nearest
        actor.addSublayer(sprite)
    }

    private func image(_ eyes: Eyes, tail: Int = 0, mouth: Bool? = nil) -> CGImage? {
        DinoSprite.image(eyes: eyes, look: Int(lookX.rounded()), mouthOpen: mouth ?? mouthOpen, tail: tail)
    }

    override func render() {
        sprite.contents = image(eyes)
        // Ngồi chơi: vẫy đuôi + chớp mắt bằng khung rời (~2 khung/giây).
        if mood == .idle, eyes == .open {
            let a = image(.open, tail: 0) as Any, b = image(.open, tail: 1) as Any, blink = image(.closed) as Any
            sprite.add(loop("contents", [a, b, a, b, a, blink, a], times: [0, 0.12, 0.24, 0.36, 0.48, 0.9, 0.94], duration: 5),
                       forKey: "idle")
        } else {
            sprite.removeAnimation(forKey: "idle")
        }
    }

    override func clearParts() { sprite.removeAllAnimations() }

    override func moodAnimations(_ mood: PetMood) {
        switch mood {
        case .idle:
            break
        case .dance:
            let a = image(.happy, tail: 0) as Any, b = image(.happy, tail: 1, mouth: true) as Any
            sprite.add(loop("contents", [a, b], times: [0, 0.5], duration: 0.42), forKey: "dance")
            root.add(loop("transform.translation.y", [0, 1, 3, 3, 1, 0], times: [0, 0.17, 0.33, 0.5, 0.67, 0.83], duration: 0.42), forKey: "bounce")
        case .sleep:
            root.add(loop("transform.scale.y", [1, 0.94], times: [0, 0.5], duration: 2.4), forKey: "breathe")
        case .alert:
            root.add(loop("transform.translation.y", [0, 4, 0, 0], times: [0, 0.1, 0.25, 0.5], duration: 1.1), forKey: "jump")
        }
    }

    /// Gầm "rawr": há miệng, rung người.
    override func special() -> (CFTimeInterval, String?) {
        eyes = .wide; mouthOpen = true
        sprite.removeAllAnimations()
        sprite.contents = image(.wide)
        actor.add(loop("transform.translation.x", [0, 1, 0, -1], times: [0, 0.25, 0.5, 0.75], duration: 0.16), forKey: "shake")
        return (1.4, "RAWR")
    }
}

// MARK: - Cassette: máy Walkman vẽ tay đeo tai nghe

final class Walkman: PetBase {
    private let body = CALayer()
    private let face = CALayer()
    private var eyeLayers: [CAShapeLayer] = []
    private var lids: [CAShapeLayer] = []
    private var smiles: [CAShapeLayer] = []
    private var reels: [CAShapeLayer] = []
    private var cups: [CAShapeLayer] = []
    private let mouth: CAShapeLayer
    private let mouthO: CAShapeLayer
    private let inkColor = NSColor(CassettePalette.ink)
    private let paper = NSColor(CassettePalette.label)
    private let orange = NSColor(CassettePalette.band)
    override var ink: NSColor { paper }

    /// Nét tay: rung nhẹ, cố định để không nhảy giữa các lần vẽ.
    private static func wobblyRect(_ r: CGRect, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let j: [CGFloat] = [0.35, -0.3, 0.25, -0.4, 0.3, -0.2, 0.4, -0.25]
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY + j[0]))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.minY + j[1]), control: CGPoint(x: r.midX, y: r.minY - 0.5))
        p.addQuadCurve(to: CGPoint(x: r.maxX + j[2], y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX + j[3], y: r.maxY - radius), control: CGPoint(x: r.maxX + 0.5, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY + j[4]), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY + j[5]), control: CGPoint(x: r.midX, y: r.maxY + 0.4))
        p.addQuadCurve(to: CGPoint(x: r.minX + j[6], y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + j[7], y: r.minY + radius), control: CGPoint(x: r.minX - 0.5, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius + 0.3, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        return p
    }

    init() {
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: -2.2, y: 0))
        smile.addQuadCurve(to: CGPoint(x: 2.2, y: 0), control: CGPoint(x: 0, y: 2))
        mouth = centered(shape(smile, fill: nil, stroke: NSColor(CassettePalette.ink), width: 1.1), at: CGPoint(x: 14, y: 21.2), size: 5)
        mouthO = centered(shape(CGPath(ellipseIn: CGRect(x: -1.5, y: -1.4, width: 3, height: 2.8), transform: nil),
                                fill: NSColor(CassettePalette.ink)), at: CGPoint(x: 14, y: 21.4), size: 3)
        super.init(size: CGSize(width: 28, height: 26), head: nil, pixel: false)
        body.frame = actor.bounds
        actor.addSublayer(body)

        // Phím bấm trên nóc máy.
        for x in [CGFloat(9.5), 14] {
            body.addSublayer(shape(CGPath(roundedRect: CGRect(x: x, y: 5, width: 3.6, height: 2.2), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil),
                                   fill: orange, stroke: inkColor, width: 0.8))
        }
        // Thân máy.
        body.addSublayer(shape(Self.wobblyRect(CGRect(x: 6.5, y: 6.5, width: 15, height: 18), radius: 2.2), fill: paper, stroke: inkColor, width: 1.2))
        body.addSublayer(shape(CGPath(rect: CGRect(x: 7.4, y: 22.2, width: 13.2, height: 1.3), transform: nil), fill: orange))
        // Cửa sổ băng + 2 trục quay.
        body.addSublayer(shape(CGPath(roundedRect: CGRect(x: 9, y: 13.6, width: 10, height: 5.4), cornerWidth: 2, cornerHeight: 2, transform: nil),
                               fill: NSColor(CassettePalette.window), stroke: inkColor, width: 0.9))
        for cx in [CGFloat(11.6), 16.4] {
            let reel = CGMutablePath()
            reel.addEllipse(in: CGRect(x: -1.6, y: -1.6, width: 3.2, height: 3.2))
            for k in 0..<3 {
                let a = CGFloat(k) * .pi / 3
                reel.move(to: CGPoint(x: -1.2 * cos(a), y: -1.2 * sin(a)))
                reel.addLine(to: CGPoint(x: 1.2 * cos(a), y: 1.2 * sin(a)))
            }
            let r = centered(shape(reel, fill: paper, stroke: inkColor, width: 0.6), at: CGPoint(x: cx, y: 16.3), size: 4)
            body.addSublayer(r)
            reels.append(r)
        }
        body.addSublayer(mouth)
        body.addSublayer(mouthO)

        face.frame = actor.bounds
        body.addSublayer(face)
        for cx in [CGFloat(11.2), 16.8] {
            let eye = centered(shape(CGPath(ellipseIn: CGRect(x: -1.2, y: -1.7, width: 2.4, height: 3.4), transform: nil), fill: inkColor),
                               at: CGPoint(x: cx, y: 10.4), size: 4)
            face.addSublayer(eye)
            eyeLayers.append(eye)
            let lid = centered(shape(arc(3.2, 1.6), fill: nil, stroke: inkColor, width: 1.1), at: CGPoint(x: cx, y: 10.6), size: 4)
            face.addSublayer(lid)
            lids.append(lid)
            let happy = centered(shape(arc(3.2, -1.8), fill: nil, stroke: inkColor, width: 1.2), at: CGPoint(x: cx, y: 11.2), size: 4)
            face.addSublayer(happy)
            smiles.append(happy)
        }

        // Tai nghe trùm đầu: vòng + 2 chụp tai (chụp nhún theo nhạc).
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 5, y: 12))
        band.addCurve(to: CGPoint(x: 23, y: 12), control1: CGPoint(x: 4, y: -1.5), control2: CGPoint(x: 24, y: -1.5))
        actor.addSublayer(shape(band, fill: nil, stroke: paper, width: 1.5))
        for cx in [CGFloat(4.6), 23.4] {
            let cup = centered(shape(CGPath(roundedRect: CGRect(x: -2.1, y: -3.4, width: 4.2, height: 6.8), cornerWidth: 1.8, cornerHeight: 1.8, transform: nil),
                                     fill: orange, stroke: inkColor, width: 0.9), at: CGPoint(x: cx, y: 13), size: 7)
            actor.addSublayer(cup)
            cups.append(cup)
        }
    }

    override func render() {
        eyeLayers.forEach {
            $0.isHidden = eyes == .closed || eyes == .happy
            $0.transform = eyes == .wide ? CATransform3DMakeScale(1.4, 1.4, 1) : CATransform3DIdentity
        }
        lids.forEach { $0.isHidden = eyes != .closed }
        smiles.forEach { $0.isHidden = eyes != .happy }
        face.transform = CATransform3DMakeTranslation(lookX * 1, 0, 0)
        mouth.isHidden = mouthOpen
        mouthO.isHidden = !mouthOpen
    }

    override func clearParts() {
        for l in [body] + eyeLayers + reels + cups { l.removeAllAnimations() }
    }

    private func spin(_ period: CFTimeInterval) {
        for r in reels {
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.toValue = 2 * Double.pi
            anim.duration = period
            anim.repeatCount = .infinity
            anim.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 30)
            r.add(anim, forKey: "spin")
        }
    }

    override func moodAnimations(_ mood: PetMood) {
        switch mood {
        case .idle:
            eyeLayers.forEach { $0.add(loop("transform.scale.y", [1, 0.15, 1], times: [0, 0.94, 0.97], duration: 5), forKey: "blink") }
        case .dance:
            root.add(loop("transform.translation.y", [0, 2.5, 0], times: [0, 0.5, 1], duration: 0.42, smooth: true), forKey: "bounce")
            body.add(loop("transform.rotation.z", [-0.07, 0.07, -0.07], times: [0, 0.5, 1], duration: 0.84, smooth: true), forKey: "sway")
            cups.forEach { $0.add(loop("transform.scale", [1, 1.18, 1], times: [0, 0.3, 1], duration: 0.42, smooth: true), forKey: "thump") }
            spin(1.2)
        case .sleep:
            root.add(loop("transform.scale.y", [1, 0.95], times: [0, 0.5], duration: 2.4), forKey: "breathe")
        case .alert:
            root.add(loop("transform.translation.y", [0, 5, 0, 0], times: [0, 0.12, 0.3, 1], duration: 1.1, smooth: true), forKey: "jump")
        }
    }

    /// Tua băng: trục quay vù vù, máy rung.
    override func special() -> (CFTimeInterval, String?) {
        spin(0.22)
        eyes = .happy; render()
        body.add(once("transform.translation.x", [0, -0.6, 0.6, -0.6, 0.6, 0], times: [0, 0.2, 0.4, 0.6, 0.8, 1], duration: 1.4), forKey: "shake")
        return (1.6, "»»")
    }
}

// MARK: - Mặc định: cáo nhỏ

final class Fox: PetBase {
    private let head = CALayer()
    private let face = CALayer()
    private let tail = CALayer()
    private var eyeLayers: [CAShapeLayer] = []
    private var lids: [CAShapeLayer] = []
    private var smiles: [CAShapeLayer] = []
    private var ears: [CAShapeLayer] = []
    private let mouth: CAShapeLayer
    private let mouthO: CAShapeLayer

    private let orange = NSColor(red: 0.98, green: 0.55, blue: 0.2, alpha: 1)
    private let deep = NSColor(red: 0.86, green: 0.42, blue: 0.13, alpha: 1)
    private let cream = NSColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
    private let dark = NSColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1)
    override var ink: NSColor { NSColor(red: 1, green: 0.7, blue: 0.45, alpha: 1) }

    init() {
        let w = CGMutablePath()
        w.move(to: CGPoint(x: -1.6, y: 0))
        w.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -0.8, y: 1.1))
        w.addQuadCurve(to: CGPoint(x: 1.6, y: 0), control: CGPoint(x: 0.8, y: 1.1))
        mouth = centered(shape(w, fill: nil, stroke: NSColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1), width: 0.8),
                         at: CGPoint(x: 13, y: 14.6), size: 4)
        mouthO = centered(shape(CGPath(ellipseIn: CGRect(x: -1.2, y: -1, width: 2.4, height: 2.2), transform: nil),
                                fill: NSColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1)), at: CGPoint(x: 13, y: 15), size: 3)
        super.init(size: CGSize(width: 26, height: 25), head: CGRect(x: 5, y: 4, width: 16, height: 10), pixel: false)

        // Đuôi xù (sau thân), gốc ở mông để vẫy.
        tail.anchorPoint = CGPoint(x: 0.62, y: 0.88)
        tail.frame = actor.bounds
        let t = CGMutablePath()
        t.move(to: CGPoint(x: 15, y: 23))
        t.addCurve(to: CGPoint(x: 24.5, y: 10), control1: CGPoint(x: 23, y: 23.5), control2: CGPoint(x: 26.5, y: 16))
        t.addCurve(to: CGPoint(x: 17.5, y: 19), control1: CGPoint(x: 22.5, y: 14), control2: CGPoint(x: 20, y: 17))
        t.closeSubpath()
        tail.addSublayer(shape(t, fill: orange))
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: 24.5, y: 10))
        tip.addCurve(to: CGPoint(x: 22.2, y: 15.2), control1: CGPoint(x: 25.6, y: 12.6), control2: CGPoint(x: 24.6, y: 14.6))
        tip.addCurve(to: CGPoint(x: 24.5, y: 10), control1: CGPoint(x: 22.6, y: 13.2), control2: CGPoint(x: 23.4, y: 11.4))
        tail.addSublayer(shape(tip, fill: cream))
        actor.addSublayer(tail)

        // Thân ngồi + yếm trắng + chân.
        actor.addSublayer(shape(CGPath(roundedRect: CGRect(x: 7.5, y: 13, width: 11, height: 11), cornerWidth: 5, cornerHeight: 5, transform: nil), fill: orange))
        actor.addSublayer(shape(CGPath(ellipseIn: CGRect(x: 10, y: 15, width: 6, height: 8), transform: nil), fill: cream))
        for x in [CGFloat(8.6), 14.4] {
            actor.addSublayer(shape(CGPath(roundedRect: CGRect(x: x, y: 22, width: 3, height: 2.4), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil), fill: dark))
        }

        // Đầu (nghiêng khi nhảy): tai nhọn, mặt cam, má + mõm trắng.
        head.anchorPoint = CGPoint(x: 0.5, y: 0.62)
        head.frame = actor.bounds
        actor.addSublayer(head)
        for (a, b, c) in [(CGPoint(x: 5.6, y: 8), CGPoint(x: 7.2, y: 0.6), CGPoint(x: 11.4, y: 5)),
                          (CGPoint(x: 14.6, y: 5), CGPoint(x: 18.8, y: 0.6), CGPoint(x: 20.4, y: 8))] {
            let ear = CGMutablePath()
            ear.addLines(between: [a, b, c])
            ear.closeSubpath()
            let inner = CGMutablePath()
            let mid = CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2)
            inner.addLines(between: [CGPoint(x: (a.x + mid.x) / 2, y: (a.y + mid.y) / 2 - 0.5),
                                     CGPoint(x: b.x + (mid.x - b.x) * 0.25, y: b.y + (mid.y - b.y) * 0.25),
                                     CGPoint(x: (c.x + mid.x) / 2, y: (c.y + mid.y) / 2 - 0.5)])
            inner.closeSubpath()
            let e = shape(ear, fill: orange)
            e.addSublayer(shape(inner, fill: dark))
            // Tai vểnh quanh chân tai khi giật mình.
            e.anchorPoint = CGPoint(x: mid.x / 26, y: mid.y / 25)
            e.frame = actor.bounds
            head.addSublayer(e)
            ears.append(e)
        }
        let skull = CGMutablePath()
        skull.move(to: CGPoint(x: 13, y: 16.6))
        skull.addCurve(to: CGPoint(x: 4.6, y: 10.4), control1: CGPoint(x: 9, y: 16.4), control2: CGPoint(x: 5.6, y: 13.4))
        skull.addCurve(to: CGPoint(x: 13, y: 3.4), control1: CGPoint(x: 4.6, y: 5.6), control2: CGPoint(x: 8.6, y: 3.4))
        skull.addCurve(to: CGPoint(x: 21.4, y: 10.4), control1: CGPoint(x: 17.4, y: 3.4), control2: CGPoint(x: 21.4, y: 5.6))
        skull.addCurve(to: CGPoint(x: 13, y: 16.6), control1: CGPoint(x: 20.4, y: 13.4), control2: CGPoint(x: 17, y: 16.4))
        head.addSublayer(shape(skull, fill: orange))
        // Vệt sẫm trên trán.
        head.addSublayer(shape(CGPath(ellipseIn: CGRect(x: 11.4, y: 4, width: 3.2, height: 2.2), transform: nil), fill: deep))
        let muzzle = CGMutablePath()
        muzzle.move(to: CGPoint(x: 13, y: 16.4))
        muzzle.addCurve(to: CGPoint(x: 5.4, y: 11.4), control1: CGPoint(x: 9.2, y: 16.2), control2: CGPoint(x: 6.4, y: 14.2))
        muzzle.addQuadCurve(to: CGPoint(x: 13, y: 11.8), control: CGPoint(x: 9.4, y: 10.2))
        muzzle.addQuadCurve(to: CGPoint(x: 20.6, y: 11.4), control: CGPoint(x: 16.6, y: 10.2))
        muzzle.addCurve(to: CGPoint(x: 13, y: 16.4), control1: CGPoint(x: 19.6, y: 14.2), control2: CGPoint(x: 16.8, y: 16.2))
        head.addSublayer(shape(muzzle, fill: cream))

        face.frame = actor.bounds
        head.addSublayer(face)
        for cx in [CGFloat(9.6), 16.4] {
            let eye = centered(shape(CGPath(ellipseIn: CGRect(x: -1.1, y: -1.5, width: 2.2, height: 3), transform: nil), fill: dark),
                               at: CGPoint(x: cx, y: 9.6), size: 4)
            eye.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -0.7, y: -1.2, width: 0.9, height: 0.9), transform: nil), fill: .white))
            face.addSublayer(eye)
            eyeLayers.append(eye)
            let lid = centered(shape(arc(3, 1.4), fill: nil, stroke: dark, width: 1), at: CGPoint(x: cx, y: 9.8), size: 4)
            face.addSublayer(lid)
            lids.append(lid)
            let happy = centered(shape(arc(3, -1.6), fill: nil, stroke: dark, width: 1.1), at: CGPoint(x: cx, y: 10.4), size: 4)
            face.addSublayer(happy)
            smiles.append(happy)
        }
        face.addSublayer(centered(shape(CGPath(ellipseIn: CGRect(x: -1.3, y: -0.9, width: 2.6, height: 1.8), transform: nil), fill: dark),
                                  at: CGPoint(x: 13, y: 13), size: 3))
        face.addSublayer(mouth)
        face.addSublayer(mouthO)
    }

    override func render() {
        eyeLayers.forEach {
            $0.isHidden = eyes == .closed || eyes == .happy
            $0.transform = eyes == .wide ? CATransform3DMakeScale(1.35, 1.35, 1) : CATransform3DIdentity
        }
        lids.forEach { $0.isHidden = eyes != .closed }
        smiles.forEach { $0.isHidden = eyes != .happy }
        mouth.isHidden = mouthOpen
        mouthO.isHidden = !mouthOpen
        face.transform = CATransform3DMakeTranslation(lookX * 1.1, 0, 0)
        ears.forEach { $0.transform = eyes == .wide ? CATransform3DMakeScale(1, 1.15, 1) : CATransform3DIdentity }
    }

    override func clearParts() {
        for l in [head, tail] + eyeLayers + ears { l.removeAllAnimations() }
    }

    private func wag(_ period: CFTimeInterval, _ amp: Double, smooth: Bool) {
        tail.add(loop("transform.rotation.z", [-amp, amp, -amp], times: [0, 0.5, 1], duration: period, smooth: smooth, fps: 20), forKey: "wag")
    }

    override func moodAnimations(_ mood: PetMood) {
        switch mood {
        case .idle:
            wag(2.4, 0.12, smooth: false)
            eyeLayers.forEach { $0.add(loop("transform.scale.y", [1, 0.15, 1], times: [0, 0.94, 0.97], duration: 4.6), forKey: "blink") }
            // Thỉnh thoảng giật tai.
            ears.first?.add(loop("transform.rotation.z", [0, 0.25, 0, 0], times: [0, 0.6, 0.64, 1], duration: 6.5), forKey: "twitch")
        case .dance:
            root.add(loop("transform.translation.y", [0, 2.5, 0], times: [0, 0.5, 1], duration: 0.42, smooth: true), forKey: "bounce")
            head.add(loop("transform.rotation.z", [-0.16, 0.16, -0.16], times: [0, 0.5, 1], duration: 0.84, smooth: true), forKey: "tilt")
            wag(0.42, 0.3, smooth: true)
        case .sleep:
            root.add(loop("transform.scale.y", [1, 0.95], times: [0, 0.5], duration: 2.4), forKey: "breathe")
            head.transform = CATransform3DMakeRotation(0.18, 0, 0, 1)
        case .alert:
            root.add(loop("transform.translation.y", [0, 5, 0, 0], times: [0, 0.12, 0.3, 1], duration: 1.1, smooth: true), forKey: "jump")
            wag(0.2, 0.15, smooth: true)
        }
    }

    override func apply(_ mood: PetMood) {
        head.transform = CATransform3DIdentity
        super.apply(mood)
    }

    /// Rình rồi vồ: thụp xuống, bật lên, đuôi quẫy.
    override func special() -> (CFTimeInterval, String?) {
        eyes = .wide; render()
        let squash = NSValue(caTransform3D: CATransform3DMakeScale(1.12, 0.86, 1))
        let id = NSValue(caTransform3D: CATransform3DIdentity)
        actor.add(once("transform", [id, squash, squash, id], times: [0, 0.3, 0.55, 0.7], duration: 1.4), forKey: "crouch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.eyes = .happy; self.render()
            self.hop(6, count: 1, period: 0.45)
        }
        wag(0.2, 0.35, smooth: true)
        return (1.7, "!")
    }
}
