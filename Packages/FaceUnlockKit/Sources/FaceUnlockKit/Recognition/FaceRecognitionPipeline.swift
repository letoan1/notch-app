//
//  FaceRecognitionPipeline.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Port notes: no `@Observable`; no Vision-feature-print fallback (fail closed: if ArcFace can't load,
//  `FaceRecognitionPipeline.make()` throws and face unlock stays unavailable).
//

import Foundation
import CoreGraphics

struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder. In-memory only; never persisted.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
}

enum FaceRecognitionPipelineError: LocalizedError {
    case noFaceDetected
    case alignmentFailed

    var errorDescription: String? {
        switch self {
        case .noFaceDetected: return "No face detected in frame."
        case .alignmentFailed: return "Could not align the detected face."
        }
    }
}

/// Thread-safe: holds only immutable state plus the (locked) embedder; all methods may run off the main thread.
final class FaceRecognitionPipeline: @unchecked Sendable {
    let embedder: FaceEmbedder

    init(embedder: FaceEmbedder) {
        self.embedder = embedder
    }

    /// Loads (and if needed compiles) ArcFace. Blocking — call from a background task.
    static func make() throws -> FaceRecognitionPipeline {
        FaceRecognitionPipeline(embedder: try ArcFaceEmbedder())
    }

    /// - Parameter previousBoundingBox: previous frame's selected box, if any — lets a continuous scanner keep
    ///   selection "stuck" to the same person instead of re-picking every frame.
    func recognize(in frame: CGImage, minimumFaceWidth: Float, preferNear previousBoundingBox: CGRect? = nil) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.selectDominantFace(in: faces, minimumFaceWidth: minimumFaceWidth, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Aligns and embeds an already-chosen face; enrollment uses this to bypass the prominence filter so a
    /// too-small face reads as "move closer" rather than "nobody there".
    func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            guard let cropped = FaceDetector.crop(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = cropped
            tier = .paddedCrop
        }

        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
    }

    /// Largest face by area with no prominence cutoff.
    static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Max normalized-coordinate drift between frames still counted as "the same person".
    private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Picks the person actually at the camera, not a bystander: filters out faces below `minimumFaceWidth`, then
    /// prefers continuity with `previousBoundingBox` over raw largest-by-area so two similarly-sized faces can't
    /// flip-flop the selection frame to frame.
    static func selectDominantFace(in faces: [DetectedFace], minimumFaceWidth: Float, preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
        let candidates = faces.filter { $0.normalizedBoundingBox.width >= CGFloat(minimumFaceWidth) }
        guard !candidates.isEmpty else { return nil }

        if let previous = previousBoundingBox {
            let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: { distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter) }),
               distance(from: nearest, to: previousCenter) < continuityDistanceTolerance {
                return nearest
            }
        }

        return candidates.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    private static func distance(from face: DetectedFace, to point: CGPoint) -> CGFloat {
        let center = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        return hypot(center.x - point.x, center.y - point.y)
    }
}

struct ScoredIdentity {
    let identity: FaceIdentity
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest individual sample.
    let maxSampleSimilarity: Float
}

extension FaceRecognitionPipeline {
    /// Sorted by centroid similarity descending; includes stale identities (different embedder) since `bestMatch`
    /// is what excludes them from actually matching.
    func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        identities.compactMap { identity in
            guard let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroidSim = FaceEmbedding.cosineSimilarity(embedding, template)
            let maxSim = identity.samples
                .map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }
                .max() ?? centroidSim
            return ScoredIdentity(identity: identity, centroidSimilarity: centroidSim, maxSampleSimilarity: maxSim)
        }.sorted { $0.centroidSimilarity > $1.centroidSimilarity }
    }

    /// Both the centroid and the closest sample must clear `threshold`. No runner-up margin check (the same person
    /// may be enrolled several times under different appearances).
    func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: embedder) else { return nil }
        guard first.centroidSimilarity >= threshold, first.maxSampleSimilarity >= threshold else { return nil }
        return first
    }
}
