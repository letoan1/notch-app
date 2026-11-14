import AVFoundation
import AppKit
import SwiftUI
import Vision

/// Webcam cho tab gương: chỉ chạy khi tab đang hiện (đèn xanh tắt ngay khi rời tab).
@MainActor
final class CameraMirror: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access = CameraMirror.currentAccess()
    /// true = soi gương (lật ngang như Photo Booth), false = hình người khác nhìn thấy.
    @Published var mirrored: Bool = UserDefaults.standard.object(forKey: "mirrorFlip") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrorFlip") }
    }
    let session = AVCaptureSession()
    /// Gợi ý căn khung / ánh sáng từ Vision (≤ 2 khung hình/giây, không lưu gì).
    @Published private(set) var guide: FaceGuide.Hint?

    private let queue = DispatchQueue(label: "notch.camera")
    private let analyzer = FaceGuide()
    private var configured = false
    private var wanted = false

    static func currentAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.access = granted ? .granted : .denied
                    if granted, self.wanted { self.start() }
                }
            }
        }
    }

    init() {
        analyzer.onHint = { [weak self] hint in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.wanted, self.guide != hint else { return }
                    self.guide = hint
                }
            }
        }
    }

    func start() {
        wanted = true
        analyzer.reset()
        access = Self.currentAccess()
        guard access == .granted else { return }
        let session = self.session
        let needsConfig = !configured
        configured = true
        // startRunning chặn ~0.5s: chạy trên queue riêng.
        queue.async {
            if needsConfig {
                session.beginConfiguration()
                // 1080p nếu camera hỗ trợ (FaceTime HD của MacBook có), .high trên Mac thường chỉ ra 720p.
                session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                // Ưu tiên camera tích hợp, không để mặc định hệ thống chọn Continuity Camera / camera ảo.
                let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                               mediaType: .video, position: .unspecified).devices.first
                if let device = builtIn ?? AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                // Ảnh nhỏ cho Vision; khung hình chỉ nằm trong RAM rồi bỏ.
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 320,
                    kCVPixelBufferHeightKey as String: 180,
                ]
                output.setSampleBufferDelegate(self.analyzer, queue: self.analyzer.queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        wanted = false
        guide = nil
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Khung hình camera, bo góc bằng layer (SwiftUI không clip được view AppKit).
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let cornerRadius: CGFloat
    let mirrored: Bool

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(session: session, cornerRadius: cornerRadius)
    }

    func updateNSView(_ view: CameraPreviewView, context: Context) {
        view.mirrored = mirrored
    }
}

final class CameraPreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private var observer: NSObjectProtocol?

    /// Tự lật bằng transform của layer: không phụ thuộc mặc định mirroring của connection
    /// (connection chỉ có sau khi session chạy trên queue riêng → lúc layout có thể chưa có).
    var mirrored = true {
        didSet { if mirrored != oldValue { needsLayout = true } }
    }

    init(session: AVCaptureSession, cornerRadius: CGFloat) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.disableAutoMirroring() }
        }
        disableAutoMirroring()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func disableAutoMirroring() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Lớp gốc tự tạo mặc định vẽ 1x → trên màn Retina hình camera bị nhoè.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        preview.contentsScale = scale
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        preview.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
        disableAutoMirroring()
    }
}

/// Phân tích khung hình camera cho tab gương: mặt lệch / quá gần / quá xa, thiếu sáng.
/// Lấy mẫu tối đa 2 lần/giây; gợi ý chỉ đổi khi giữ nguyên 2 lần liên tiếp (không nhấp nháy).
final class FaceGuide: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Hint: Equatable {
        case moveLeft, moveRight, tooHigh, tooLow, tooClose, tooFar, noFace
        /// Mặt (hoặc cả khung nếu không thấy mặt) quá tối.
        case dark
    }

    let queue = DispatchQueue(label: "notch.camera.vision", qos: .utility)
    var onHint: ((Hint?) -> Void)?

    // Chỉ dùng trên `queue`.
    private var lastSample: CFTimeInterval = 0
    private var candidate: Hint??
    private var current: Hint?? = .none
    private var noFaceStreak = 0

    func reset() {
        queue.async { [self] in
            lastSample = 0
            candidate = nil
            current = .none
            noFaceStreak = 0
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastSample >= 0.5, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSample = now

        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        let face = (request.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        // Vision: gốc dưới-trái, toạ độ 0…1 trên ảnh camera gốc (chưa lật gương).
        let box = face?.boundingBox
        let luma = Self.meanLuma(pixels, in: box ?? CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))

        let hint: Hint?
        if luma < 0.28 {
            hint = .dark
        } else if let box {
            noFaceStreak = 0
            hint = Self.framing(box)
        } else {
            noFaceStreak += 1
            hint = noFaceStreak >= 4 ? .noFace : current ?? nil
        }
        publish(hint)
    }

    private func publish(_ hint: Hint?) {
        guard candidate == .some(hint) else { candidate = .some(hint); return }
        guard current != .some(hint) else { return }
        current = .some(hint)
        onHint?(hint)
    }

    private static func framing(_ b: CGRect) -> Hint? {
        if b.height > 0.62 { return .tooClose }
        if b.height < 0.2 { return .tooFar }
        // Ảnh gốc: mặt ở nửa trái ảnh = người đang lệch về bên phải của họ → dịch sang trái.
        if b.midX < 0.36 { return .moveLeft }
        if b.midX > 0.64 { return .moveRight }
        if b.midY > 0.72 { return .tooHigh }
        if b.midY < 0.36 { return .tooLow }
        return nil
    }

    /// Độ sáng trung bình 0…1 trong vùng `rect` (toạ độ Vision) của ảnh BGRA.
    private static func meanLuma(_ buffer: CVPixelBuffer, in rect: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 1 }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = max(0, Int(rect.minX * CGFloat(w))), x1 = min(w, Int(rect.maxX * CGFloat(w)))
        // Vision gốc dưới, bộ đệm gốc trên → lật trục y.
        let y0 = max(0, Int((1 - rect.maxY) * CGFloat(h))), y1 = min(h, Int((1 - rect.minY) * CGFloat(h)))
        guard x1 > x0, y1 > y0 else { return 1 }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, n = 0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                let i = y * row + x * 4
                sum += 0.0722 * Double(p[i]) + 0.7152 * Double(p[i + 1]) + 0.2126 * Double(p[i + 2])
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) / 255 : 1
    }
}
