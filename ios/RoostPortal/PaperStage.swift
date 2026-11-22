import SceneKit
import UIKit
import CoreImage

// MARK: - Sân khấu tờ giấy trên iPhone

/// Ảnh đang cầm được vẽ thành tờ giấy 3D (cùng kiểu gấp với Roost trên Mac). Càng gần mép trái càng gấp
/// thành máy bay giấy, sát mép là máy bay hẳn và bay đi. SCNView trong suốt phủ cả màn hình, không nhận chạm,
/// chỉ vẽ trong lúc đang cầm ảnh.
final class PaperStage: SCNView {
    static let shared = PaperStage(frame: UIScreen.main.bounds, options: nil)

    private let front = SCNMaterial()
    private var paper: OrigamiPaper?
    private let shadow = SCNNode()   // bóng mờ vẽ sẵn, rẻ hơn filter blur mỗi khung
    private var paperSize = CGSize(width: 160, height: 120)
    private var near: Double = 0
    private var tilt: Double = 0
    private var point: CGPoint = .zero

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        antialiasingMode = .multisampling4X
        isHidden = true
        let scene = SCNScene()
        let fov = 28.0
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera!.fieldOfView = fov
        cam.camera!.zNear = 10
        cam.camera!.zFar = 5000
        cam.position = SCNVector3(0, 0, Float(Double(frame.height) / 2 / tan(fov / 2 * .pi / 180)))   // mặt z = 0 = màn hình
        scene.rootNode.addChildNode(cam)
        pointOfView = cam
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 850
        key.position = SCNVector3(0, 0, 600)
        key.look(at: SCNVector3(-90, -160, 0))
        scene.rootNode.addChildNode(key)
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light!.type = .ambient
        amb.light!.intensity = 260
        scene.rootNode.addChildNode(amb)
        let sm = SCNMaterial()
        sm.lightingModel = .constant
        sm.diffuse.contents = UIColor.black
        sm.transparent.contents = Self.shadowTexture()
        sm.transparencyMode = .aOne
        sm.writesToDepthBuffer = false
        shadow.geometry = SCNPlane(width: 1, height: 1)
        shadow.geometry!.firstMaterial = sm
        shadow.renderingOrder = -1
        scene.rootNode.addChildNode(shadow)
        front.lightingModel = .physicallyBased
        front.roughness.contents = 0.55
        self.scene = scene
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(size: CGSize) {
        paper?.root.removeFromParentNode()
        let back = SCNMaterial()
        back.lightingModel = .physicallyBased
        back.diffuse.contents = UIColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)
        back.roughness.contents = 0.9
        let keel = size.height * 0.155, nose = size.width * 0.357
        let p = OrigamiPaper(L: size.width, Wd: size.height, keel: keel, nose: nose, front: front, back: back)
        scene?.rootNode.addChildNode(p.root)
        paper = p
        paperSize = size
    }

    private func scenePoint(_ p: CGPoint) -> SCNVector3 {
        SCNVector3(Float(p.x - bounds.width / 2), Float(bounds.height / 2 - p.y), 0)
    }

    /// Gấp theo độ gần mép: nửa đầu gập hai mũi, nửa sau gập thân và cánh.
    private func fold(_ k: Double) -> OrigamiFold {
        func seg(_ a: Double, _ b: Double) -> Double { min(max((k - a) / (b - a), 0), 1) }
        let e = { (x: Double) in x * x * (3 - 2 * x) }
        let f = OrigamiFold.folded
        return OrigamiFold(keel: f.keel * e(seg(0.35, 1)), wing: f.wing * e(seg(0.35, 1)),
                           triL: f.triL * e(seg(0, 0.55)), triR: f.triR * e(seg(0.05, 0.6)))
    }

    private func apply(z: Double, scale: Double = 1) {
        guard let paper else { return }
        let pos = scenePoint(point)
        let k = near
        paper.root.position = SCNVector3(pos.x, pos.y, Float(z))
        // phẳng: ảnh hướng về người xem; càng gấp càng quay mũi sang trái, nghiêng theo vận tốc
        paper.root.eulerAngles = SCNVector3(Float(0.5 * k), Float(tilt * .pi / 180 * 0.5), Float(0.12 * k))
        paper.root.scale = SCNVector3(scale, scale, scale)
        paper.apply(fold(k))
        // bóng: lệch theo độ cao, hẹp lại khi gấp thành máy bay
        shadow.position = SCNVector3(pos.x - Float(0.3 * z), pos.y - Float(0.5 * z), -1)
        shadow.scale = SCNVector3(Float(paperSize.width * 1.35 * scale), Float(paperSize.height * 1.35 * scale * (1 - 0.55 * k)), 1)
        shadow.opacity = CGFloat(0.45 / (1 + z / 160))
    }

    // MARK: API

    func show(image: UIImage?, size: CGSize, at p: CGPoint) {
        if paper == nil || paperSize != size { build(size: size) }
        front.diffuse.contents = Self.sheet(image)
        near = 0; tilt = 0; point = p
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        apply(z: 40)
        SCNTransaction.commit()
        paper?.root.opacity = 1
        inUse = true
        isHidden = false
        isPlaying = true
    }

    func setImage(_ image: UIImage) { front.diffuse.contents = Self.sheet(image) }

    func update(at p: CGPoint, near n: Double, tilt t: Double) {
        guard !isHidden else { return }
        point = p; near = n; tilt = t
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.08
        apply(z: 40 + 30 * n)
        SCNTransaction.commit()
    }

    /// Bay ra khỏi mép trái: gấp hẳn thành máy bay rồi lao đi.
    func fling(to p: CGPoint, duration: Double, done: @escaping () -> Void) {
        point = p; near = 1; tilt = -20
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeIn)
        SCNTransaction.completionBlock = { [weak self] in self?.hide(); done() }
        apply(z: 120, scale: 0.8)
        SCNTransaction.commit()
    }

    /// Không đủ lực: mở phẳng lại và về chỗ cũ.
    func drop(to p: CGPoint, done: @escaping () -> Void) {
        point = p; near = 0; tilt = 0
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        SCNTransaction.completionBlock = { [weak self] in self?.hide(); done() }
        apply(z: 0, scale: 0.8)
        SCNTransaction.commit()
    }

    /// Vẽ trước vài khung gần như trong suốt khi mở app để SceneKit biên dịch shader, lần nhấc ảnh đầu không khựng.
    func warmUp() {
        guard isHidden else { return }
        if paper == nil { build(size: paperSize) }
        paper?.root.opacity = 0.01
        shadow.opacity = 0
        isHidden = false
        isPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.inUse else { return }
            self.hide()
            self.paper?.root.opacity = 1
        }
    }
    private var inUse = false

    private func hide() {
        inUse = false
        isHidden = true
        isPlaying = false
    }

    private static func shadowTexture() -> UIImage {
        let s = CGSize(width: 256, height: 192)
        let base = UIGraphicsImageRenderer(size: s).image { ctx in
            UIColor.black.setFill()
            UIBezierPath(roundedRect: CGRect(x: 40, y: 34, width: 176, height: 124), cornerRadius: 14).fill()
        }
        let ci = CIImage(image: base)!.clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: CGRect(origin: .zero, size: s))
        guard let cg = CIContext().createCGImage(ci, from: CGRect(origin: .zero, size: s)) else { return base }
        return UIImage(cgImage: cg)
    }

    /// Mặt trước tờ giấy 4:3, ảnh lấp đầy.
    private static func sheet(_ image: UIImage?) -> UIImage {
        let s = CGSize(width: 480, height: 360)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: s))
            guard let image, image.size.width > 0, image.size.height > 0 else { return }
            let k = max(s.width / image.size.width, s.height / image.size.height)
            let d = CGSize(width: image.size.width * k, height: image.size.height * k)
            image.draw(in: CGRect(x: (s.width - d.width) / 2, y: (s.height - d.height) / 2, width: d.width, height: d.height))
        }
    }
}

// MARK: - Tờ giấy gấp được (giống Roost trên Mac)

struct OrigamiFold {
    var keel, wing, triL, triR: Double
    static let folded = OrigamiFold(keel: 78 * .pi / 180, wing: 70 * .pi / 180, triL: 178 * .pi / 180, triR: 178 * .pi / 180)
}

/// Một tờ giấy (mặt trước in ảnh) chia thành các mặt nối bản lề, gấp cứng thành máy bay phi tiêu và mở lại.
/// Trục x dọc thân (mũi ở -L/2), y ngang.
final class OrigamiPaper {
    let root = SCNNode()
    private let keelL = SCNNode(), keelR = SCNNode(), wingL = SCNNode(), wingR = SCNNode(), triL = SCNNode(), triR = SCNNode()
    private let axisL: SCNVector3, axisR: SCNVector3

    init(L: CGFloat, Wd: CGFloat, keel k: CGFloat, nose n: CGFloat, front: SCNMaterial, back: SCNMaterial) {
        let hw = Wd / 2, x0 = -L / 2, x1 = L / 2
        func panel(_ pts: [CGPoint], hinge h: CGPoint) -> SCNGeometry {
            var v: [SCNVector3] = [], nf: [SCNVector3] = [], uv: [CGPoint] = []
            for z in [Float(1), -1] {
                for p in pts {
                    v.append(SCNVector3(Float(p.x - h.x), Float(p.y - h.y), 0))
                    nf.append(SCNVector3(0, 0, z))
                    uv.append(CGPoint(x: (p.x - x0) / L, y: (hw - p.y) / Wd))
                }
            }
            let c = Int32(pts.count)
            var fi: [Int32] = [], bi: [Int32] = []
            for i in 1..<(c - 1) { fi += [0, i, i + 1]; bi += [c, c + i + 1, c + i] }
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
        wingL.position = SCNVector3(0, Float(k), 0)
        wingR.position = SCNVector3(0, Float(-k), 0)
        triL.position = SCNVector3(Float(x0), 0, 0)
        triR.position = SCNVector3(Float(x0), 0, 0)
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
        keelL.rotation = SCNVector4(1, 0, 0, Float(f.keel))
        keelR.rotation = SCNVector4(1, 0, 0, Float(-f.keel))
        wingL.rotation = SCNVector4(1, 0, 0, Float(-f.wing))
        wingR.rotation = SCNVector4(1, 0, 0, Float(f.wing))
        triL.rotation = SCNVector4(axisL.x, axisL.y, axisL.z, Float(-f.triL))
        triR.rotation = SCNVector4(axisR.x, axisR.y, axisR.z, Float(f.triR))
    }
}

/// Đưa sân khấu SceneKit dùng chung vào SwiftUI.
import SwiftUI
struct PaperStageView: UIViewRepresentable {
    func makeUIView(context: Context) -> PaperStage { PaperStage.shared }
    func updateUIView(_ uiView: PaperStage, context: Context) {}
}
