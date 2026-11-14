//
//  CameraManager.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Owns the AVCaptureSession and exposes the newest camera frame as a CGImage. Runs entirely on-device; frames are
//  only held in memory, never written anywhere.
//  Port notes: `@Observable` → plain `@MainActor` class with an `onFrame` callback (publishing ~30 fps through
//  `@Published` would spam SwiftUI hosts); `start()` never requests camera access itself — it only uses an existing
//  grant, so the host decides when the permission prompt appears (`FaceUnlockService.requestCameraAccess()`).
//

@preconcurrency import AVFoundation
import CoreImage

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
struct CameraFrame: @unchecked Sendable {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

@MainActor
final class CameraManager: NSObject {
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Called on the main actor for every new frame while running.
    var onFrame: ((CameraFrame) -> Void)?
    /// Read on every `start()` so a camera preference change takes effect without a restart.
    var preferredDeviceID: () -> String? = { nil }

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "FaceUnlockKit.camera.session")

    /// Handed to the delegate outside the actor; only ever touched via `Task { @MainActor ... }`.
    private let framePublisher = FramePublisher()

    override init() {
        super.init()
        framePublisher.owner = self
    }

    /// Returns false (with `errorMessage` set) when access isn't already granted or no device exists.
    @discardableResult
    func start() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            errorMessage = status == .restricted
                ? "Camera access is restricted by Screen Time or an MDM profile."
                : "Camera access not granted. Enable it in System Settings > Privacy & Security > Camera."
            return false
        }

        errorMessage = nil
        configureSessionIfNeeded()
        reconcileDeviceIfNeeded()
        guard errorMessage == nil else { return false }

        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
        isRunning = true
        return true
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
        isRunning = false
        currentFrame = nil
    }

    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    private func reconcileDeviceIfNeeded() {
        guard let device = CameraDeviceCatalog.resolvedDevice(preferredID: preferredDeviceID()) else {
            errorMessage = "No camera device found."
            return
        }
        guard device.uniqueID != currentInput?.device.uniqueID else { return }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            selectHighestResolutionFormat(for: device)
        } else {
            currentInput = nil
            errorMessage = "No camera device found."
        }
        session.commitConfiguration()
    }

    /// Highest resolution regardless of fps — Vision works from the downscaled frame; this only affects what
    /// `CameraFrame.source` (and therefore `renderCrop`) has to work with.
    private func selectHighestResolutionFormat(for device: AVCaptureDevice) {
        let best = device.formats.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
        guard let best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            // Non-fatal: keep the preset's format.
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        guard isRunning else { return }
        currentFrame = frame
        onFrame?(frame)
    }

    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for spoof-cue extraction which
    /// needs pixel detail (screen texture, gloss) the downscaled working frame throws away.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Expand ~1.3x so device edges/bezels are captured.
        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up.
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    /// `CIContext` is expensive to create and safe to reuse concurrently.
    private nonisolated static let cropRenderContext = CIContext()

    /// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there, then hops back.
    private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        weak var owner: CameraManager?
        private let ciContext = CIContext()
        /// Detection only needs a modest resolution; the undownscaled `source` is kept for `renderCrop`.
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceExtent = sourceImage.extent
            var ciImage = sourceImage
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(
                id: nextFrameID,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size
            )

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
