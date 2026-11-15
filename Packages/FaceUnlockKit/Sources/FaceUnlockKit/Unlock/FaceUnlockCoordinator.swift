//
//  FaceUnlockCoordinator.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Connects face recognition to the actual unlock path: lock/wake triggers → scan window → (match AND liveness)
//  → verify real lock state → type the stored password + Return.
//
//  Port notes: UI-agnostic. Every NotchOverlayController / NotchGeometry / GlanceSettings / POCController / SpaceKeyMonitor
//  reference is gone; the host observes `phase` and drives its own UI (and may call `startScan()` e.g. on hover).
//  Added: `.unlocked` / `.unlockNotConfirmed` resolution after typing, explicit readiness reasons.
//
//  Known limitation (from Glance): liveness defeats a photo but not reliably a replayed video — a successful spoof types
//  the real macOS password.
//

import Foundation
import CoreGraphics

/// What the unlock engine is doing right now. The host animates from this.
public enum FaceUnlockPhase: Equatable, Sendable {
    case idle
    case scanning
    /// Face + liveness passed and the password was typed; waiting for macOS to report the screen unlocked.
    case matched
    case failed(FaceUnlockFailure)
    /// macOS reported the screen unlocked after a match.
    case unlocked
}

public enum FaceUnlockFailure: Equatable, Sendable {
    /// A face was seen but consistently didn't match an enrolled identity.
    case notRecognized
    /// A liveness deny cue fired (screen glare / device bezel); associated text explains which.
    case livenessFailed(String)
    /// No usable face during the whole scan window.
    case noFace
    case cameraUnavailable(String)
    /// Prerequisite missing (session locked, no password, model failed, no Accessibility, nothing enrolled...).
    case notReady(String)
    /// Matched, but reading/typing the password failed (or the lock check refused to type).
    case injectionFailed(String)
    /// Password typed but the screen stayed locked (stale stored password?).
    case unlockNotConfirmed
}

@MainActor
final class FaceUnlockCoordinator {
    struct Dependencies {
        let lockMonitor: LockMonitor
        let camera: CameraManager
        let store: FaceEnrollmentStore
        let settings: () -> FaceUnlockSettings
        let pipeline: () -> FaceRecognitionPipeline?
        let pipelineError: () -> String?
        /// True while the host runs enrollment — the camera is busy and scanning must not start.
        let isEnrolling: () -> Bool
        /// Notch port: false = automatic triggers (lock/wake/auto-retry) are suspended by the host.
        let autoScanAllowed: () -> Bool
    }

    private let deps: Dependencies
    var onPhaseChange: ((FaceUnlockPhase) -> Void)?
    var onStatusChange: ((String) -> Void)?
    /// Notch port: đã khớp mặt, đang chờ dấu hiệu người thật → UI gợi ý chớp mắt.
    var onAwaitingLiveness: ((Bool) -> Void)?
    private var awaitingLiveness = false {
        didSet { if awaitingLiveness != oldValue { onAwaitingLiveness?(awaitingLiveness) } }
    }
    /// Notch port: thời gian từng bước của lần quét gần nhất (giây), để biết chậm ở đâu.
    private(set) var lastTiming: (camera: Double, face: Double?, match: Double?, live: Double?, total: Double)?
    private var cameraStartSeconds: Double = 0

    private(set) var phase: FaceUnlockPhase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    private(set) var statusMessage = "Idle" {
        didSet { if statusMessage != oldValue { onStatusChange?(statusMessage) } }
    }
    /// Diagnostic detail of the last decision (similarity, liveness cue). Never contains secrets.
    private(set) var lastOutcome: String?
    /// Điểm giống cao nhất của lần quét gần nhất (để chỉnh ngưỡng theo số liệu thật).
    private(set) var lastBestSimilarity: Float?
    /// Thấp hơn ngưỡng ít nhất chừng này mới coi là "người khác" và dừng sớm; hụt ít hơn thì quét tới hết giờ
    /// (camera vừa thức còn đang chỉnh sáng, mặt nghiêng, mờ chuyển động).
    private let wrongFaceMargin: Float = 0.2

    /// A wake often catches the owner still looking away; require a sustained non-match before failing.
    private let wrongFaceGraceDuration: Duration = .seconds(2)
    private var hasArmedForCurrentLock = false
    /// One-shot per lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    private var autoRetryTask: Task<Void, Never>?
    private let retryDelay: Duration = .seconds(1)
    private var confirmTask: Task<Void, Never>?
    /// How long after typing to wait for macOS to report the screen unlocked.
    private let unlockConfirmTimeout: Duration = .seconds(6)

    init(dependencies: Dependencies) {
        deps = dependencies
        deps.lockMonitor.onEvent = { [weak self] _ in
            Task { @MainActor [weak self] in
                // Brief settle delay: CGSession's reported state can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.evaluateTrigger()
            }
        }
    }

    // MARK: - Public control

    /// Called by the service when settings change; disabling cancels any in-flight scan immediately.
    func settingsDidChange() {
        if !deps.settings().isEnabled { disarm(resetPhase: true) }
    }

    /// Manual scan (e.g. the host's notch was hovered/clicked on the lock screen). Same gates as automatic triggers.
    @discardableResult
    func startScan() -> Bool {
        guard LockMonitor.isScreenActuallyLocked() else {
            statusMessage = "Screen is not locked."
            return false
        }
        if case .scanning = phase { return true }
        if case .matched = phase { return false }
        if let reason = notReadyReason() {
            statusMessage = reason
            phase = .failed(.notReady(reason))
            return false
        }
        startScanCycle()
        return true
    }

    func cancelScan() {
        disarm(resetPhase: true)
    }

    /// nil when everything needed for an unlock is in place.
    func notReadyReason() -> String? {
        let settings = deps.settings()
        guard settings.isEnabled else { return "Face unlock is turned off." }
        guard !deps.isEnrolling() else { return "Enrollment in progress." }
        guard deps.pipeline() != nil else {
            return "Face model unavailable: \(deps.pipelineError() ?? "still loading")."
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            return "Face unlock is on, but the session is locked — authenticate once (Touch ID) in the app first."
        }
        guard SecureCredentialManager.hasStoredPassword() else { return "No password is stored yet." }
        guard !deps.store.activeIdentities.isEmpty else { return "No face is enrolled." }
        guard KeystrokeInjector.isAccessibilityTrusted() else { return "Accessibility permission is not granted." }
        return nil
    }

    // MARK: - Triggering

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            let wasMatched = phase == .matched
            disarm(resetPhase: false)
            phase = wasMatched ? .unlocked : .idle
            if wasMatched { statusMessage = "Unlocked." }
            return
        }
        guard !deps.lockMonitor.isSleeping else { return }

        // `.wake` is an explicit "let me back in," so clear the one-shot guard — unless it's part of the same burst.
        if deps.lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        let settings = deps.settings()
        guard settings.isEnabled, !hasArmedForCurrentLock, deps.autoScanAllowed() else { return }
        guard let trigger = requiredTrigger(for: deps.lockMonitor.lastEvent),
              settings.triggers.contains(trigger) else { return }

        if let reason = notReadyReason() {
            statusMessage = reason
            return
        }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // Brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, LockMonitor.isScreenActuallyLocked() else { return }
            self.startScanCycle()
        }
    }

    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    private func requiredTrigger(for event: LockEventKind?) -> FaceUnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarm(resetPhase: Bool) {
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still in flight inert.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        confirmTask?.cancel()
        confirmTask = nil
        if !deps.isEnrolling() { deps.camera.stop() }
        if resetPhase { phase = .idle }
    }

    // MARK: - Scan cycle

    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its side effects (`camera.stop()`) must not land on the newer cycle.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard let pipeline = deps.pipeline() else {
            phase = .failed(.notReady("Face model unavailable."))
            return
        }

        let cameraStart = ContinuousClock.now
        guard deps.camera.start() else {
            let message = deps.camera.errorMessage ?? "Camera unavailable."
            statusMessage = message
            phase = .failed(.cameraUnavailable(message))
            return
        }
        guard generation == scanGeneration else { return }
        cameraStartSeconds = Self.seconds(ContinuousClock.now - cameraStart)

        phase = .scanning
        statusMessage = "Looking for your face…"

        let settings = deps.settings()
        let outcome = await observeScanWindow(
            pipeline: pipeline,
            deadline: Date().addingTimeInterval(TimeInterval(settings.scanSeconds)),
            generation: generation
        )

        // A newer cycle now owns the camera — leave it alone.
        guard generation == scanGeneration else { return }
        deps.camera.stop()

        switch outcome {
        case .matched(let name):
            await injectPassword(matchedName: name, generation: generation)
        case .consistentlyWrongFace:
            statusMessage = "Face not recognized."
            phase = .failed(.notRecognized)
            scheduleAutoRetryIfEnabled()
        case .spoofSuspected(let reason):
            statusMessage = "Couldn't confirm a live face."
            phase = .failed(.livenessFailed(reason))
            scheduleAutoRetryIfEnabled()
        case .noResolution:
            guard LockMonitor.isScreenActuallyLocked() else { return }
            statusMessage = "No face detected."
            phase = .failed(.noFace)
            scheduleAutoRetryIfEnabled()
        case .cancelled:
            break
        }
    }

    private func scheduleAutoRetryIfEnabled() {
        guard deps.settings().autoRetryOnce, !hasAutoRetriedForCurrentLock, deps.autoScanAllowed() else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.retryDelay)
            guard !Task.isCancelled else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password meanwhile.
            guard LockMonitor.isScreenActuallyLocked(), self.deps.settings().isEnabled else { return }
            if case .failed = self.phase { self.startScanCycle() }
        }
    }

    // MARK: - Password injection

    private func injectPassword(matchedName: String, generation: Int) async {
        // Last gates right before the secret is touched. `KeystrokeInjector` re-checks the lock between batches too.
        guard deps.settings().isEnabled, generation == scanGeneration else { return }
        guard LockMonitor.isScreenActuallyLocked() else {
            statusMessage = "Skipped: the session server reports the screen is not actually locked."
            phase = .idle
            return
        }
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            phase = .failed(.injectionFailed("Accessibility permission is not granted."))
            return
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            phase = .failed(.injectionFailed("Session locked — authenticate with Touch ID in the app first."))
            return
        }

        statusMessage = "Recognized \(matchedName) — unlocking…"
        phase = .matched
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
            // The screen may have unlocked by other means while we were about to type.
            phase = LockMonitor.isScreenActuallyLocked() ? .failed(.injectionFailed(error.localizedDescription)) : .idle
            return
        }

        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.unlockConfirmTimeout)
            guard !Task.isCancelled, self.phase == .matched else { return }
            if LockMonitor.isScreenActuallyLocked() {
                self.statusMessage = "Password typed but the Mac is still locked — is the stored password current?"
                self.phase = .failed(.unlockNotConfirmed)
            } else {
                self.phase = .unlocked
            }
        }
    }

    // MARK: - Scan window

    private enum ScanOutcome {
        case matched(String)
        case consistentlyWrongFace
        case spoofSuspected(String)
        case noResolution
        case cancelled
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second
    /// lands; liveness never fails the scan by staying undecided, it just keeps scanning until `deadline`.
    private func observeScanWindow(pipeline: FaceRecognitionPipeline, deadline: Date, generation: Int) async -> ScanOutcome {
        let settings = deps.settings()
        let livenessEnabled = settings.livenessMode != .off
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { [weak self] in
            self?.deps.settings().livenessMode == .heavy ? .heavy : .light
        }
        let minimumFaceWidth = settings.minimumFaceWidth

        var wrongFaceStartedAt: ContinuousClock.Instant?
        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        let scanStart = ContinuousClock.now
        var firstFaceAt: Double?
        var firstMatchAt: Double?
        var liveAt: Double?
        defer { awaitingLiveness = false }
        var lastProcessedFrameID: UInt64?
        var bestSimilarity: Float?
        lastBestSimilarity = nil
        defer { lastBestSimilarity = bestSimilarity }

        while Date() < deadline {
            guard !Task.isCancelled, generation == scanGeneration else { return .cancelled }
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = deps.camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, minimumFaceWidth: minimumFaceWidth,
                                                           preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays a genuinely independent gate.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    let reason = snapshot.decision.denialReason ?? "Liveness check failed."
                    lastOutcome = reason
                    return .spoofSuspected(reason)
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // `activeIdentities`: someone switched off stays enrolled but must not unlock.
            let scored = pipeline.score(result.embedding, against: deps.store.activeIdentities)
            let threshold = deps.settings().matchThreshold
            let matched = pipeline.bestMatch(in: scored, threshold: threshold)
            let similarity = scored.first.map { min($0.centroidSimilarity, $0.maxSampleSimilarity) }
            if let similarity { bestSimilarity = max(bestSimilarity ?? similarity, similarity) }

            if firstFaceAt == nil { firstFaceAt = Self.seconds(ContinuousClock.now - scanStart) }
            if let matched {
                wrongFaceStartedAt = nil
                readyMatch = matched
                if firstMatchAt == nil { firstMatchAt = Self.seconds(ContinuousClock.now - scanStart) }
            } else if (similarity ?? 0) >= threshold - wrongFaceMargin {
                // Hụt ngưỡng một chút: chưa kết luận, quét tiếp.
                readyMatch = nil
                wrongFaceStartedAt = nil
            } else {
                readyMatch = nil
                let started = wrongFaceStartedAt ?? .now
                wrongFaceStartedAt = started
                if ContinuousClock.now - started >= wrongFaceGraceDuration {
                    lastOutcome = scored.first.map { "Best similarity \(String(format: "%.3f", $0.centroidSimilarity))." }
                    return .consistentlyWrongFace
                }
            }

            if livenessConfirmed, liveAt == nil { liveAt = Self.seconds(ContinuousClock.now - scanStart) }
            awaitingLiveness = readyMatch != nil && !livenessConfirmed
            if let readyMatch, livenessConfirmed {
                lastTiming = (cameraStartSeconds, firstFaceAt, firstMatchAt, liveAt,
                              cameraStartSeconds + Self.seconds(ContinuousClock.now - scanStart))
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                return .matched(readyMatch.identity.name)
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // Hết giờ mà đã thấy mặt (chỉ hụt ngưỡng): là "không nhận ra", không phải "không thấy mặt".
        if let bestSimilarity {
            lastOutcome = "Best similarity \(String(format: "%.3f", bestSimilarity))."
            return .consistentlyWrongFace
        }
        return .noResolution
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
