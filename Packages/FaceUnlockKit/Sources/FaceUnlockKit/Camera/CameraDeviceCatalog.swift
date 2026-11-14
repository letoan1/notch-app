//
//  CameraDeviceCatalog.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Port note: Glance's built-in vs. external display camera overrides (GlanceSettings) are reduced to one
//  optional preferred device ID supplied by the host.
//

import AVFoundation

public struct CameraDevice: Identifiable, Hashable, Sendable {
    public let id: String // AVCaptureDevice.uniqueID
    public let name: String
}

/// Notch port: only real cameras are allowed for face unlock. Rule (documented in README):
/// - built-in wide-angle camera (MacBook / iMac / Studio Display), or
/// - an external camera on USB transport,
/// and in both cases name / model / manufacturer must not look like a virtual camera
/// (OBS, Snap, Camo, mmhmm, Ecamm, ManyCam, XSplit, NVIDIA Broadcast, DroidCam, iVCam, EpocCam, …).
/// Continuity Camera (iPhone over the network) and anything with a virtual / unknown transport is rejected.
enum CameraDeviceCatalog {
    private static let virtualKeywords = [
        "virtual", "obs ", "obs-", "snap camera", "camo", "mmhmm", "ecamm", "manycam", "xsplit", "cameo",
        "nvidia broadcast", "logi capture", "streamlabs", "vcam", "reincubate", "epoccam", "ivcam", "droidcam",
        "iriun", "camera hub", "screen", "desk view", "continuity", "zoom", "teams", "loopback", "syphon", "ndi",
    ]

    private static func fourCC(_ s: String) -> Int32 {
        s.utf8.reduce(0) { ($0 << 8) | Int32($1) }
    }

    static func looksVirtual(_ device: AVCaptureDevice) -> Bool {
        let text = [device.localizedName, device.modelID, device.manufacturer].joined(separator: " ").lowercased()
        return virtualKeywords.contains { text.contains($0) }
    }

    /// See the rule above.
    static func isTrusted(_ device: AVCaptureDevice) -> Bool {
        guard !looksVirtual(device) else { return false }
        switch device.deviceType {
        case .builtInWideAngleCamera:
            return true
        case .external:
            return device.transportType == fourCC("usb ")
        default:
            return false
        }
    }

    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.filter(isTrusted).map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Preferred device if connected and trusted, then the built-in front camera, then the first trusted camera.
    static func resolvedDevice(preferredID: String?) -> AVCaptureDevice? {
        if let preferredID, let device = AVCaptureDevice(uniqueID: preferredID), isTrusted(device) {
            return device
        }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front), isTrusted(device) {
            return device
        }
        return availableDevices().first.flatMap { AVCaptureDevice(uniqueID: $0.id) }
    }
}
