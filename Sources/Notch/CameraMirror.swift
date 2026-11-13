import AVFoundation
import AppKit
import SwiftUI

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

    private let queue = DispatchQueue(label: "notch.camera")
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

    func start() {
        wanted = true
        access = Self.currentAccess()
        guard access == .granted else { return }
        let session = self.session
        let needsConfig = !configured
        configured = true
        // startRunning chặn ~0.5s: chạy trên queue riêng.
        queue.async {
            if needsConfig {
                session.beginConfiguration()
                session.sessionPreset = .high
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        wanted = false
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        preview.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
        disableAutoMirroring()
    }
}
