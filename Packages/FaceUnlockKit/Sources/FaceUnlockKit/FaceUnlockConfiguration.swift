//
//  FaceUnlockConfiguration.swift
//  FaceUnlockKit
//
//  Replaces Glance's GlanceSettings singleton: identifiers chosen by the host app (fixed at init)
//  plus user-tunable settings persisted in UserDefaults.
//

import Foundation

/// Fixed per-host identifiers. Set once when `FaceUnlockService` is created; never change them later
/// or previously stored credentials/embeddings become unreachable.
public struct FaceUnlockConfiguration: Sendable {
    /// Keychain `kSecAttrService` for the session key and encrypted password blob.
    public var keychainService: String
    /// Folder under ~/Library/Application Support holding the encrypted face store and the compiled model cache.
    public var storageDirectoryName: String
    /// UserDefaults key prefix for `FaceUnlockSettings`.
    public var defaultsPrefix: String
    /// Optional explicit location of `ArcFace.mlpackage` or `ArcFace.mlmodelc` (otherwise searched, see `ArcFaceModelStore`).
    public var modelURL: URL?
    /// How the session key that encrypts the password + embeddings is protected. See `CredentialProtection`.
    public var credentialProtection: CredentialProtection
    /// See `ArcFaceModelCachePolicy`; `.perLaunch` (default) recompiles the bundled model each launch (~0.1 s).
    public var modelCachePolicy: ArcFaceModelCachePolicy

    public init(
        keychainService: String,
        storageDirectoryName: String,
        defaultsPrefix: String = "FaceUnlockKit",
        modelURL: URL? = nil,
        credentialProtection: CredentialProtection = .keychainUserPresence,
        modelCachePolicy: ArcFaceModelCachePolicy = .perLaunch
    ) {
        self.keychainService = keychainService
        self.storageDirectoryName = storageDirectoryName
        self.defaultsPrefix = defaultsPrefix
        self.modelURL = modelURL
        self.credentialProtection = credentialProtection
        self.modelCachePolicy = modelCachePolicy
    }
}

/// Protection of the session key (AES-256) that encrypts the stored password and the face embeddings.
public enum CredentialProtection: Sendable, Equatable {
    /// Glance's model: Keychain item with `SecAccessControl(.userPresence)` — the OS itself demands Touch ID / password
    /// on every read. Requires the app to be signed by an Apple Developer team with a `keychain-access-groups`
    /// entitlement; otherwise unlocking the session fails with `missingKeychainEntitlement` (-34018).
    case keychainUserPresence
    /// For self-signed / ad-hoc builds: key stored as a normal login-keychain item (ACL = this app's code signature),
    /// released by FaceUnlockKit only after `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` succeeds.
    /// Weaker: the Touch ID gate is enforced by app code, not by the Keychain.
    case localAuthenticationGate
}

/// Process-wide copy of the configuration for the static (non-instance) security helpers ported from Glance.
enum FaceUnlockEnvironment {
    private static let lock = NSLock()
    private static var _configuration = FaceUnlockConfiguration(
        keychainService: "FaceUnlockKit",
        storageDirectoryName: "FaceUnlockKit"
    )

    static var configuration: FaceUnlockConfiguration {
        get { lock.lock(); defer { lock.unlock() }; return _configuration }
        set { lock.lock(); _configuration = newValue; lock.unlock() }
    }

    /// Path only — no side effects (safe for existence checks).
    static var storageDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(configuration.storageDirectoryName, isDirectory: true)
    }

    /// Creates the folder (0700) if needed — use before writing.
    static var storageDirectory: URL {
        let directory = storageDirectoryURL
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}

/// Liveness strictness. `off` lets recognition alone decide (a photo of the enrolled user would pass).
public enum FaceUnlockLivenessMode: String, CaseIterable, Sendable {
    case off
    /// Deny cues only (screen glare, device bezel). Glance's default.
    case light
    /// Deny cues plus at least one confirm cue (3D geometry, nose parallax, blink).
    case heavy
}

/// Which lock-screen signals start a scan automatically. The host can always call `startScan()` manually.
public enum FaceUnlockTrigger: String, CaseIterable, Sendable {
    /// Display woke (system wake, display wake, screensaver stopped).
    case onWake
    /// Screen just locked.
    case onLock
}

/// User-tunable settings, persisted in UserDefaults (`defaultsPrefix`.*). Mutate via `FaceUnlockService.settings`.
public struct FaceUnlockSettings: Equatable, Sendable {
    /// Off by default — the host enables it after enrollment + password setup.
    public var isEnabled: Bool = false
    /// Cosine-similarity gate; both the identity centroid and its closest sample must reach it. Glance default 0.66.
    public var matchThreshold: Float = 0.66
    public var livenessMode: FaceUnlockLivenessMode = .light
    /// Faces narrower than this fraction of the frame are treated as bystanders. Glance default 0.21.
    public var minimumFaceWidth: Float = 0.21
    public var triggers: Set<FaceUnlockTrigger> = [.onWake, .onLock]
    /// Length of one scan cycle, clamped to 3...10 s.
    public var scanSeconds: Int = 5
    /// Retry once automatically after a failed/no-face cycle (once per lock session).
    public var autoRetryOnce: Bool = false
    /// Idle limit after which the Touch-ID session re-locks; `nil` = only on app exit / explicit lock. Glance default 30 days.
    public var sessionIdleLimit: TimeInterval? = 30 * 24 * 60 * 60
    /// `AVCaptureDevice.uniqueID`; nil = system default front camera.
    public var cameraDeviceID: String?

    public static let scanSecondsRange = 3...10

    public init() {}

    static func load(prefix: String, defaults: UserDefaults = .standard) -> FaceUnlockSettings {
        var s = FaceUnlockSettings()
        func key(_ name: String) -> String { "\(prefix).\(name)" }
        if let v = defaults.object(forKey: key("isEnabled")) as? Bool { s.isEnabled = v }
        if let v = defaults.object(forKey: key("matchThreshold")) as? Float { s.matchThreshold = v }
        if let v = defaults.string(forKey: key("livenessMode")).flatMap(FaceUnlockLivenessMode.init(rawValue:)) { s.livenessMode = v }
        if let v = defaults.object(forKey: key("minimumFaceWidth")) as? Float { s.minimumFaceWidth = v }
        if let raw = defaults.array(forKey: key("triggers")) as? [String] {
            s.triggers = Set(raw.compactMap(FaceUnlockTrigger.init(rawValue:)))
        }
        if let v = defaults.object(forKey: key("scanSeconds")) as? Int { s.scanSeconds = v }
        if let v = defaults.object(forKey: key("autoRetryOnce")) as? Bool { s.autoRetryOnce = v }
        if let v = defaults.object(forKey: key("sessionIdleLimit")) as? Double { s.sessionIdleLimit = v > 0 ? v : nil }
        s.cameraDeviceID = defaults.string(forKey: key("cameraDeviceID"))
        return s.normalized()
    }

    func save(prefix: String, defaults: UserDefaults = .standard) {
        func key(_ name: String) -> String { "\(prefix).\(name)" }
        defaults.set(isEnabled, forKey: key("isEnabled"))
        defaults.set(matchThreshold, forKey: key("matchThreshold"))
        defaults.set(livenessMode.rawValue, forKey: key("livenessMode"))
        defaults.set(minimumFaceWidth, forKey: key("minimumFaceWidth"))
        defaults.set(triggers.map(\.rawValue).sorted(), forKey: key("triggers"))
        defaults.set(scanSeconds, forKey: key("scanSeconds"))
        defaults.set(autoRetryOnce, forKey: key("autoRetryOnce"))
        defaults.set(sessionIdleLimit ?? 0, forKey: key("sessionIdleLimit"))
        defaults.set(cameraDeviceID, forKey: key("cameraDeviceID"))
    }

    /// Clamps values into safe ranges so a bad write can't, e.g., set the match threshold to 0.
    func normalized() -> FaceUnlockSettings {
        var s = self
        s.scanSeconds = min(max(s.scanSeconds, Self.scanSecondsRange.lowerBound), Self.scanSecondsRange.upperBound)
        s.matchThreshold = min(max(s.matchThreshold, 0.4), 0.95)
        s.minimumFaceWidth = min(max(s.minimumFaceWidth, 0.05), 0.6)
        return s
    }
}
