//
//  FaceUnlockService.swift
//  FaceUnlockKit
//
//  Public facade over the Glance-derived core (Glance: MIT, © Jonathan Zhou). Replaces Glance's AppEnvironment /
//  POCController / onboarding glue with one UI-agnostic ObservableObject. The host draws all UI from the published state.
//

import Foundation
import AppKit
import AVFoundation
import Combine

public struct FaceIdentitySummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let sampleCount: Int
    public let isEnabled: Bool
    public let createdAt: Date
    /// Enrolled with a different embedding model — must be re-enrolled before it can match.
    public let isStale: Bool
}

public enum FaceUnlockModelState: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

public enum CameraPermissionStatus: Sendable {
    case notDetermined, granted, denied, restricted
}

public enum FaceUnlockServiceError: LocalizedError {
    case modelNotReady(String)
    case cameraUnavailable(String)
    case enrollmentNotStarted
    case enrollmentIncomplete
    case screenLocked
    case scanInProgress

    public var errorDescription: String? {
        switch self {
        case .modelNotReady(let detail): return "Face model not ready: \(detail)"
        case .cameraUnavailable(let detail): return detail
        case .enrollmentNotStarted: return "No enrollment is in progress."
        case .enrollmentIncomplete: return "Enrollment hasn't captured every pose yet."
        case .screenLocked: return "Can't enroll while the screen is locked."
        case .scanInProgress: return "A face-unlock scan is in progress."
        }
    }
}

@MainActor
public final class FaceUnlockService: ObservableObject {
    // MARK: Published state

    /// Unlock engine state — animate the notch from this.
    @Published public private(set) var phase: FaceUnlockPhase = .idle
    /// Human-readable status line (English), e.g. "Looking for your face…".
    @Published public private(set) var statusMessage: String = "Idle"
    /// Notch port: đã nhận ra mặt, chờ xác nhận người thật (gợi ý chớp mắt).
    @Published public private(set) var awaitingLiveness = false
    /// Notch port: thời gian từng bước của lần quét gần nhất (giây).
    public var lastScanTiming: (camera: Double, face: Double?, match: Double?, live: Double?, total: Double)? { coordinator.lastTiming }
    /// Non-nil while a guided enrollment is running (or completed, awaiting `finishEnrollment`).
    @Published public private(set) var enrollment: EnrollmentProgress?
    @Published public private(set) var identities: [FaceIdentitySummary] = []
    /// Touch-ID session open (password + embeddings decryptable).
    // Placeholders only: real values are read in `init` *after* the configuration (keychain service, storage folder)
    // is installed — property initializers run before the init body.
    @Published public private(set) var isSessionUnlocked: Bool = false
    @Published public private(set) var hasStoredPassword: Bool = false
    /// Encrypted face data exists on disk (answerable while the session is locked).
    @Published public private(set) var hasEnrollmentData: Bool = false
    @Published public private(set) var modelState: FaceUnlockModelState = .loading
    /// Mirrors the (spoofable) lock notifications — for UI only; security checks use the session server directly.
    @Published public private(set) var isScreenLocked: Bool = false
    /// Persisted; assigning applies immediately (disabling cancels any scan).
    @Published public var settings: FaceUnlockSettings {
        didSet {
            let normalized = settings.normalized()
            if normalized != settings { settings = normalized; return }
            settings.save(prefix: configuration.defaultsPrefix)
            coordinator.settingsDidChange()
        }
    }

    /// Notch port: host-controlled kill switch for automatic scans (e.g. after repeated failures in one lock period).
    /// Manual `startScan()` is not affected — the host gates that itself.
    public var autoScanSuspended = false

    /// Notch port: the capture session used for enrollment, for a live `AVCaptureVideoPreviewLayer`.
    public var previewSession: AVCaptureSession { camera.session }

    // MARK: Internals

    public let configuration: FaceUnlockConfiguration
    private let lockMonitor: LockMonitor
    private let camera: CameraManager
    private let store: FaceEnrollmentStore
    private var coordinator: FaceUnlockCoordinator!
    private var autoLocker: SessionAutoLocker!
    private var pipeline: FaceRecognitionPipeline?
    private var enrollmentSession: EnrollmentSession?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionObserver: NSObjectProtocol?

    /// Create once per process (it owns the camera, lock observers and the session auto-locker).
    public init(configuration: FaceUnlockConfiguration) {
        // Must come first: every Keychain/storage helper below reads it.
        FaceUnlockEnvironment.configuration = configuration
        ArcFaceModelStore.cachePolicy = configuration.modelCachePolicy
        self.configuration = configuration
        self.settings = FaceUnlockSettings.load(prefix: configuration.defaultsPrefix)
        lockMonitor = LockMonitor()
        camera = CameraManager()
        store = FaceEnrollmentStore()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        hasEnrollmentData = SecureFaceStore.exists

        camera.preferredDeviceID = { [weak self] in self?.settings.cameraDeviceID }
        camera.onFrame = { [weak self] frame in self?.enrollmentSession?.process(frame) }

        coordinator = FaceUnlockCoordinator(dependencies: .init(
            lockMonitor: lockMonitor,
            camera: camera,
            store: store,
            settings: { [weak self] in self?.settings ?? FaceUnlockSettings() },
            pipeline: { [weak self] in self?.pipeline },
            pipelineError: { [weak self] in
                if case .failed(let message) = self?.modelState { return message }
                return nil
            },
            isEnrolling: { [weak self] in self?.enrollmentSession != nil },
            autoScanAllowed: { [weak self] in !(self?.autoScanSuspended ?? true) }
        ))
        coordinator.onPhaseChange = { [weak self] phase in self?.phase = phase }
        coordinator.onStatusChange = { [weak self] message in self?.statusMessage = message }
        coordinator.onAwaitingLiveness = { [weak self] waiting in self?.awaitingLiveness = waiting }

        autoLocker = SessionAutoLocker(idleLimitProvider: { [weak self] in self?.settings.sessionIdleLimit })
        autoLocker.onDidLock = { [weak self] in self?.refreshCredentialState() }

        store.$identities
            .sink { [weak self] identities in self?.publishIdentities(identities) }
            .store(in: &cancellables)
        lockMonitor.$isScreenLocked
            .sink { [weak self] locked in
                self?.isScreenLocked = locked
                // Enrollment must never keep the camera running behind a locked screen.
                if locked, self?.enrollmentSession != nil { self?.cancelEnrollment() }
            }
            .store(in: &cancellables)
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshCredentialState() }
        }

        loadModel()
    }

    deinit {
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
    }

    private func loadModel() {
        modelState = .loading
        Task { [weak self] in
            let result: Result<FaceRecognitionPipeline, Error> = await Task.detached(priority: .utility) {
                Result { try FaceRecognitionPipeline.make() }
            }.value
            guard let self else { return }
            switch result {
            case .success(let pipeline):
                self.pipeline = pipeline
                self.modelState = .ready
                self.publishIdentities(self.store.identities)
            case .failure(let error):
                self.modelState = .failed(error.localizedDescription)
            }
        }
    }

    private func publishIdentities(_ identities: [FaceIdentity]) {
        let currentModel = pipeline?.embedder.modelIdentifier
        self.identities = identities.map { identity in
            FaceIdentitySummary(
                id: identity.id, name: identity.name, sampleCount: identity.samples.count, isEnabled: identity.isEnabled,
                createdAt: identity.createdAt, isStale: currentModel.map { identity.modelIdentifier != $0 } ?? false
            )
        }
        hasEnrollmentData = SecureFaceStore.exists
    }

    private func refreshCredentialState() {
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        hasEnrollmentData = SecureFaceStore.exists
    }

    // MARK: - Unlock API

    /// Convenience for `settings.isEnabled`.
    public var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    /// nil when face unlock could run right now (ignoring whether the screen is locked); otherwise why not.
    public var notReadyReason: String? { coordinator.notReadyReason() }

    /// Start a scan now (only while the screen is actually locked) — e.g. when the user hovers/taps the notch.
    @discardableResult
    public func startScan() -> Bool { coordinator.startScan() }

    public func cancelScan() { coordinator.cancelScan() }

    // MARK: - Credential API (Touch ID gate)

    /// Shows the Touch ID / password sheet and opens the session (creating the session key on first use).
    public func unlockSession(reason: String = "Authenticate to set up face unlock") async throws {
        defer { refreshCredentialState() }
        try await SecureCredentialManager.unlockSession(reason: reason)
        store.reloadIfUnlocked()
    }

    /// Re-locks the session now (password + embeddings unreadable until the next `unlockSession`).
    public func lockSession() {
        SecureCredentialManager.lockSession()
        refreshCredentialState()
    }

    /// Encrypts and stores the macOS login password. Prompts Touch ID first if the session isn't open.
    /// FaceUnlockKit cannot verify the password is correct — a wrong one surfaces later as `.unlockNotConfirmed`.
    public func storePassword(_ password: String, reason: String = "Authenticate to store your Mac password") async throws {
        guard !password.isEmpty else { throw SecureCredentialError.emptyPassword }
        if !SecureCredentialManager.isSessionUnlocked {
            try await unlockSession(reason: reason)
        }
        try await Task.detached(priority: .userInitiated) {
            guard var bytes = password.data(using: .utf8) else { throw SecureCredentialError.emptyPassword }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            try SecureCredentialManager.savePassword(bytes)
        }.value
        refreshCredentialState()
    }

    /// Deletes only the stored password (faces stay enrolled). Face unlock stops working until a new one is stored.
    public func deleteStoredPassword() throws {
        defer { refreshCredentialState() }
        try SecureCredentialManager.deletePasswordOnly()
    }

    /// Full reset: password, session keys and the encrypted face store. Disables face unlock.
    public func resetAll() throws {
        cancelEnrollment()
        coordinator.cancelScan()
        settings.isEnabled = false
        defer { refreshCredentialState() }
        try SecureCredentialManager.deleteAllCredentials()
        store.deleteAll()
    }

    /// Idle limit after which the session re-locks (nil = never while the app runs). Persisted in `settings`.
    public var sessionIdleLimit: TimeInterval? {
        get { settings.sessionIdleLimit }
        set { settings.sessionIdleLimit = newValue }
    }

    // MARK: - Enrollment API

    /// Exact while the session is open; while it's locked, falls back to "an encrypted face store exists".
    public var hasEnrollment: Bool { store.isLocked ? SecureFaceStore.exists : !store.identities.isEmpty }

    /// Starts guided capture (camera on). Requires camera permission already granted and the model loaded.
    /// Pass `replacing:` to re-capture an existing identity.
    public func startEnrollment(replacing identityID: UUID? = nil) throws {
        guard !LockMonitor.isScreenActuallyLocked() else { throw FaceUnlockServiceError.screenLocked }
        if case .scanning = phase { throw FaceUnlockServiceError.scanInProgress }
        guard let pipeline else {
            if case .failed(let message) = modelState { throw FaceUnlockServiceError.modelNotReady(message) }
            throw FaceUnlockServiceError.modelNotReady("still loading")
        }
        cancelEnrollment()
        let session = EnrollmentSession(pipeline: pipeline, minimumFaceWidth: settings.minimumFaceWidth, replacing: identityID)
        session.onChange = { [weak self] progress in
            guard let self, self.enrollmentSession === session else { return }
            self.enrollment = progress
            if progress.isComplete { self.camera.stop() }
        }
        enrollmentSession = session
        guard camera.start() else {
            enrollmentSession = nil
            enrollment = nil
            throw FaceUnlockServiceError.cameraUnavailable(camera.errorMessage ?? "Camera unavailable.")
        }
        session.begin()
    }

    /// Stops capture and discards in-memory samples.
    public func cancelEnrollment() {
        guard enrollmentSession != nil else { return }
        enrollmentSession = nil
        enrollment = nil
        camera.stop()
    }

    /// Saves the captured samples (encrypted) under `name`. Prompts Touch ID first if the session isn't open.
    @discardableResult
    public func finishEnrollment(name: String, reason: String = "Authenticate to save your face") async throws -> FaceIdentitySummary {
        guard let session = enrollmentSession else { throw FaceUnlockServiceError.enrollmentNotStarted }
        guard session.isComplete else { throw FaceUnlockServiceError.enrollmentIncomplete }
        guard let pipeline else { throw FaceUnlockServiceError.modelNotReady("not loaded") }
        if !SecureCredentialManager.isSessionUnlocked {
            try await unlockSession(reason: reason)
        }
        store.reloadIfUnlocked()
        let identity = try store.commitEnrollment(
            replacing: session.replacingIdentityID,
            name: name,
            samples: session.makeSamples(),
            embedder: pipeline.embedder
        )
        enrollmentSession = nil
        enrollment = nil
        camera.stop()
        refreshCredentialState()
        return FaceIdentitySummary(
            id: identity.id, name: identity.name, sampleCount: identity.samples.count, isEnabled: identity.isEnabled,
            createdAt: identity.createdAt, isStale: false
        )
    }

    public func deleteIdentity(id: UUID) throws {
        try store.delete(id: id)
    }

    public func setIdentityEnabled(_ enabled: Bool, id: UUID) throws {
        try store.setEnabled(enabled, for: id)
    }

    // MARK: - Permissions

    public static var cameraPermission: CameraPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    /// Shows the system camera prompt if undetermined (host decides when). Returns whether access is granted.
    public static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Needed to type the password on the lock screen. No prompt.
    public static var isAccessibilityTrusted: Bool { KeystrokeInjector.isAccessibilityTrusted() }

    /// Shows the system Accessibility prompt (deep-links to System Settings). Host decides when.
    @discardableResult
    public static func promptForAccessibility() -> Bool { KeystrokeInjector.promptForAccessibility() }

    public static func availableCameras() -> [CameraDevice] { CameraDeviceCatalog.availableDevices() }

    // MARK: - Lock screen helper

    /// Moves a host window above the lock screen (private SkyLight API). Only acts while actually locked.
    @discardableResult
    public static func moveToLockScreen(_ window: NSWindow) -> Bool { LockScreenWindowHelper.moveToLockScreen(window) }

    public static func restoreFromLockScreen(_ window: NSWindow) { LockScreenWindowHelper.restoreFromLockScreen(window) }

    /// Authoritative lock state (CGSession), safe for gating.
    public static var isScreenActuallyLocked: Bool { LockMonitor.isScreenActuallyLocked() }
}
