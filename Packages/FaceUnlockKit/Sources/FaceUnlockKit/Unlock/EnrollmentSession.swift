//
//  EnrollmentSession.swift
//  FaceUnlockKit
//
//  Adapted from Glance's Onboarding/OnboardingController.swift (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  The guided-capture logic only (9 head poses x 2 samples, pose bands, hold/streak debounce, quality + 5-point
//  alignment gates), lifted out of Glance's SwiftUI onboarding. All window/animation/naming/password steps are dropped;
//  the host renders `EnrollmentProgress`. Samples stay in memory until `FaceUnlockService.finishEnrollment`.
//

import Foundation
import CoreGraphics

/// A guided head pose — center plus the 8 compass directions, in the order presented to the user.
public enum EnrollmentPose: Int, CaseIterable, Sendable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    enum YawBand { case left, none, right }
    enum PitchBand { case up, none, down }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: return .left
        case .right, .topRight, .bottomRight: return .right
        case .center, .top, .bottom: return .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: return .up
        case .bottom, .bottomLeft, .bottomRight: return .down
        case .center, .left, .right: return .none
        }
    }

    /// Compass angle (0 = up, clockwise) for drawing a ring sector; nil for center.
    public var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .left: return 270
        case .topLeft: return 315
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        }
    }

    public var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Turn your head slightly left"
        case .topLeft: return "Turn your head to the top left"
        case .top: return "Turn your head slightly up"
        case .topRight: return "Turn your head to the top right"
        case .right: return "Turn your head slightly right"
        case .bottomRight: return "Turn your head to the bottom right"
        case .bottom: return "Turn your head slightly down"
        case .bottomLeft: return "Turn your head to the bottom left"
        }
    }

    /// Relaxes this pose's yaw/pitch bands — same knob as `stallWidenFactor`, so >1 is easier.
    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: return 1.5
        case .bottom: return 1.2
        default: return 1
        }
    }

    /// Persisted alongside each sample.
    public var name: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top_left"
        case .top: return "top"
        case .topRight: return "top_right"
        case .right: return "right"
        case .bottomRight: return "bottom_right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom_left"
        }
    }
}

public enum EnrollmentExcessiveTurn: Sendable, Equatable {
    case left, topLeft, up, topRight, right, bottomRight, down, bottomLeft

    public var instruction: String {
        switch self {
        case .left: return "Too far left"
        case .topLeft: return "Too far toward the top left"
        case .up: return "Too far up"
        case .topRight: return "Too far toward the top right"
        case .right: return "Too far right"
        case .bottomRight: return "Too far toward the bottom right"
        case .down: return "Too far down"
        case .bottomLeft: return "Too far toward the bottom left"
        }
    }
}

/// Live head direction for a ring indicator.
public struct EnrollmentHeadTurn: Equatable, Sendable {
    /// Compass angle (0 = up, clockwise) — same frame as `EnrollmentPose.compassAngle`.
    public let angle: Double
    /// How far the turn has gone toward the current pose's threshold, 0...1.
    public let progress: Double
}

/// Everything a host needs to draw guided enrollment. Published by `FaceUnlockService.enrollment`.
public struct EnrollmentProgress: Equatable, Sendable {
    public var currentPose: EnrollmentPose?
    /// Poses fully captured.
    public var capturedPoses: Set<EnrollmentPose>
    /// 0...1 per direction (captured samples / samplesPerPose).
    public var poseProgress: [EnrollmentPose: Double]
    public var samplesPerPose: Int
    /// 0...1 over all poses.
    public var overallProgress: Double
    /// What to tell the user right now (pose guidance, "Bring your face closer", "Too far left", ...).
    public var instruction: String
    public var faceDetected: Bool
    public var isTooFar: Bool
    public var excessiveTurn: EnrollmentExcessiveTurn?
    public var headTurn: EnrollmentHeadTurn?
    /// All poses captured; call `FaceUnlockService.finishEnrollment(name:)`.
    public var isComplete: Bool
    /// Camera/model problem that stopped enrollment, if any.
    public var error: String?
}

@MainActor
final class EnrollmentSession {
    struct CollectedSample {
        let embedding: [Float]
        let pose: EnrollmentPose
        let quality: Float?
        /// Stamped at capture, not at save.
        let capturedAt: Date
    }

    let replacingIdentityID: UUID?
    private let pipeline: FaceRecognitionPipeline
    private let minimumFaceWidth: Float
    var onChange: ((EnrollmentProgress) -> Void)?

    // MARK: Tuning (Glance values)

    /// 9 poses x 2 samples = 18 total.
    let samplesPerPose = 2
    /// Consecutive matching frames required before a capture fires.
    private let requiredMatchStreak = 3
    /// Wait this long after yaw/pitch matches before samples count.
    private let poseHoldDuration: Duration = .milliseconds(500)
    /// Permissive floor for Vision's capture-quality score.
    private let qualityFloor: Float = 0.2
    /// Hold off accepting captures this long once the camera comes up (first samples mid-blink).
    private let initialCaptureDelay: Duration = .seconds(1.5)
    // Pose-matching bands, in radians. Vision: +yaw = left turn, -pitch = looking up.
    private let yawInnerThreshold: Float = 0.24
    private let yawCenterTolerance: Float = 0.18
    private let yawOuterCap: Float = 0.51
    private let pitchInnerThreshold: Float = 0.17
    private let pitchCenterTolerance: Float = 0.15
    private let pitchOuterCap: Float = 0.37
    /// If a pose takes longer than this, matching bands widen by `stallWidenFactor`.
    private let stallTimeout: Duration = .seconds(12)
    private let stallWidenFactor: Float = 1.25
    private let headTurnDeadzone: Double = 0.15

    // MARK: State

    private(set) var collectedSamples: [CollectedSample] = []
    private var currentPoseIndex = 0
    private var capturedForCurrentPose = 0
    private var capturedPoses: Set<EnrollmentPose> = []
    private var faceDetected = false
    private var currentYaw: Float?
    private var currentPitch: Float?
    private var isTooFar = false
    private var excessiveTurn: EnrollmentExcessiveTurn?
    private(set) var isComplete = false
    private var error: String?
    private var matchStreak = 0
    private var isProcessingFrame = false
    private var poseStartedAt: ContinuousClock.Instant = .now
    private var captureReadyAt: ContinuousClock.Instant = .now
    private var poseHoldStartedAt: ContinuousClock.Instant?

    init(pipeline: FaceRecognitionPipeline, minimumFaceWidth: Float, replacing identityID: UUID?) {
        self.pipeline = pipeline
        // Enrollment wants a closer face than unlock's bystander cutoff.
        self.minimumFaceWidth = max(minimumFaceWidth, 0.2)
        self.replacingIdentityID = identityID
    }

    func begin() {
        poseStartedAt = .now
        captureReadyAt = .now + initialCaptureDelay
        poseHoldStartedAt = nil
        emit()
    }

    func fail(_ message: String) {
        error = message
        emit()
    }

    var currentPose: EnrollmentPose? { EnrollmentPose(rawValue: currentPoseIndex) }

    var progress: EnrollmentProgress {
        var perPose: [EnrollmentPose: Double] = [:]
        for pose in EnrollmentPose.allCases {
            if pose.rawValue < currentPoseIndex { perPose[pose] = 1 }
            else if pose.rawValue == currentPoseIndex { perPose[pose] = Double(capturedForCurrentPose) / Double(samplesPerPose) }
            else { perPose[pose] = 0 }
        }
        let total = Double(EnrollmentPose.allCases.count * samplesPerPose)
        let done = Double(currentPoseIndex * samplesPerPose + capturedForCurrentPose)
        return EnrollmentProgress(
            currentPose: isComplete ? nil : currentPose,
            capturedPoses: capturedPoses,
            poseProgress: perPose,
            samplesPerPose: samplesPerPose,
            overallProgress: min(done / total, 1),
            instruction: instruction,
            faceDetected: faceDetected,
            isTooFar: isTooFar,
            excessiveTurn: excessiveTurn,
            headTurn: headTurn,
            isComplete: isComplete,
            error: error
        )
    }

    private var instruction: String {
        if let error { return error }
        if isComplete { return "Face captured" }
        if let excessiveTurn { return excessiveTurn.instruction }
        if isTooFar { return "Bring your face closer" }
        if !faceDetected { return "Position your face in front of the camera" }
        return currentPose?.instruction ?? ""
    }

    private var headTurn: EnrollmentHeadTurn? {
        guard !isComplete, faceDetected, !isTooFar, excessiveTurn == nil,
              let pose = currentPose, pose != .center,
              let yaw = currentYaw, let pitch = currentPitch else { return nil }
        // Vision inverts both axes vs. the screen: +yaw turns left, +pitch looks down.
        let x = Double(-yaw / (yawInnerThreshold / pose.matchLeniency))
        let y = Double(-pitch / (pitchInnerThreshold / pose.matchLeniency))
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > headTurnDeadzone else { return nil }
        let degrees = atan2(x, y) * 180 / .pi
        return EnrollmentHeadTurn(angle: degrees < 0 ? degrees + 360 : degrees, progress: min(magnitude, 1))
    }

    private func emit() { onChange?(progress) }

    // MARK: Frame processing

    private enum FrameOutcome {
        case noFace
        case tooFar
        case ready(FaceRecognitionResult)
    }

    /// Drops frames while one is still being processed (Vision + ArcFace run off the main actor).
    func process(_ frame: CameraFrame) {
        guard !isComplete, error == nil, !isProcessingFrame, let pose = currentPose else { return }
        isProcessingFrame = true
        let pipeline = self.pipeline
        let minimumWidth = minimumFaceWidth
        let image = frame.image
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> FrameOutcome in
                do {
                    let faces = try FaceDetector.detectFaces(in: image)
                    guard let face = FaceRecognitionPipeline.largestFace(in: faces) else { return .noFace }
                    if Float(face.normalizedBoundingBox.width) < minimumWidth { return .tooFar }
                    return .ready(try pipeline.recognize(face, in: image))
                } catch {
                    return .noFace
                }
            }.value
            guard let self else { return }
            self.isProcessingFrame = false
            self.handle(outcome, pose: pose)
            self.emit()
        }
    }

    private func handle(_ outcome: FrameOutcome, pose: EnrollmentPose) {
        guard !isComplete, currentPose == pose else { return }
        switch outcome {
        case .noFace:
            faceDetected = false
            resetTracking(tooFar: false)
        case .tooFar:
            faceDetected = true
            resetTracking(tooFar: true)
        case .ready(let result):
            guard let yaw = result.face.yaw, let pitch = result.face.pitch else {
                faceDetected = true
                resetTracking(tooFar: false)
                return
            }
            faceDetected = true
            currentYaw = yaw
            currentPitch = pitch
            isTooFar = false
            excessiveTurn = excessiveTurnDirection(yaw: yaw, pitch: pitch)
            guard excessiveTurn == nil else {
                matchStreak = 0
                poseHoldStartedAt = nil
                return
            }
            processMatched(result, yaw: yaw, pitch: pitch, pose: pose)
        }
    }

    private func resetTracking(tooFar: Bool) {
        currentYaw = nil
        currentPitch = nil
        matchStreak = 0
        poseHoldStartedAt = nil
        isTooFar = tooFar
        excessiveTurn = nil
    }

    private func processMatched(_ result: FaceRecognitionResult, yaw: Float, pitch: Float, pose: EnrollmentPose) {
        guard ContinuousClock.now >= captureReadyAt else {
            matchStreak = 0
            poseHoldStartedAt = nil
            return
        }

        let qualityOK = result.quality.map { $0 >= qualityFloor } ?? true
        // Only a 5-point alignment is reliably canonical.
        let alignmentOK = result.alignmentTier == .fivePoint
        let widened = ContinuousClock.now - poseStartedAt > stallTimeout
        let poseOK = poseMatches(yaw: yaw, pitch: pitch, pose: pose, widened: widened)
        guard qualityOK, alignmentOK, poseOK else {
            matchStreak = 0
            poseHoldStartedAt = nil
            return
        }

        if poseHoldStartedAt == nil { poseHoldStartedAt = .now }
        guard let holdStart = poseHoldStartedAt, ContinuousClock.now - holdStart >= poseHoldDuration else { return }

        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        collectedSamples.append(CollectedSample(
            embedding: result.embedding, pose: pose, quality: result.quality, capturedAt: Date()
        ))
        capturedForCurrentPose += 1

        if capturedForCurrentPose >= samplesPerPose {
            capturedPoses.insert(pose)
            currentPoseIndex += 1
            capturedForCurrentPose = 0
            poseStartedAt = .now
            poseHoldStartedAt = nil
            if currentPoseIndex >= EnrollmentPose.allCases.count {
                isComplete = true
            }
        }
    }

    private func poseMatches(yaw: Float, pitch: Float, pose: EnrollmentPose, widened: Bool) -> Bool {
        let factor = (widened ? stallWidenFactor : 1.0) * pose.matchLeniency
        return yawMatches(yaw, band: pose.yawBand, factor: factor)
            && pitchMatches(pitch, band: pose.pitchBand, factor: factor)
    }

    private func yawMatches(_ yaw: Float, band: EnrollmentPose.YawBand, factor: Float) -> Bool {
        switch band {
        case .none: return abs(yaw) < yawCenterTolerance * factor
        case .left: return yaw > yawInnerThreshold / factor && yaw < yawOuterCap
        case .right: return yaw < -yawInnerThreshold / factor && yaw > -yawOuterCap
        }
    }

    /// Vision reports negative pitch for "looking up" and positive for "looking down".
    private func pitchMatches(_ pitch: Float, band: EnrollmentPose.PitchBand, factor: Float) -> Bool {
        switch band {
        case .none: return abs(pitch) < pitchCenterTolerance * factor
        case .up: return pitch < -pitchInnerThreshold / factor && pitch > -pitchOuterCap
        case .down: return pitch > pitchInnerThreshold / factor && pitch < pitchOuterCap
        }
    }

    /// Dominant axis when the user has gone beyond the safe pose envelope.
    private func excessiveTurnDirection(yaw: Float, pitch: Float) -> EnrollmentExcessiveTurn? {
        let yawOvershoot = abs(yaw) / yawOuterCap
        let pitchOvershoot = abs(pitch) / pitchOuterCap
        guard max(yawOvershoot, pitchOvershoot) >= 1 else { return nil }

        if yawOvershoot >= 1, pitchOvershoot >= 1 {
            switch (yaw > 0, pitch < 0) {
            case (true, true): return .topLeft
            case (false, true): return .topRight
            case (false, false): return .bottomRight
            case (true, false): return .bottomLeft
            }
        }
        if yawOvershoot >= pitchOvershoot {
            return yaw > 0 ? .left : .right
        }
        return pitch < 0 ? .up : .down
    }

    func makeSamples() -> [FaceSample] {
        collectedSamples.map {
            FaceSample(embedding: $0.embedding, pose: $0.pose.name, capturedAt: $0.capturedAt, quality: $0.quality)
        }
    }
}
