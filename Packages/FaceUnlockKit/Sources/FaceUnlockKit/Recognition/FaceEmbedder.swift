//
//  FaceEmbedder.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Port note: Glance's `VisionFeaturePrintEmbedder` fallback is dropped — upstream itself notes it is
//  "too thin to gate unlock on". If ArcFace can't load, FaceUnlockKit fails closed (unlock unavailable).
//

import Foundation
import CoreGraphics

protocol FaceEmbedder: AnyObject, Sendable {
    var name: String { get }
    /// Persisted alongside every sample; used to refuse comparing across different embedders
    /// (which wouldn't error, just produce confident nonsense).
    var modelIdentifier: String { get }
    var embeddingDimension: Int { get }
    /// Whether this embedder needs a canonically-aligned input.
    var requiresAlignment: Bool { get }
    func embedding(for face: CGImage) throws -> [Float]
}

enum FaceEmbedding {
    /// Scales `vector` to unit length; matters once vectors are combined (see `average` below).
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity, range -1...1.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Normalize each sample, average, then renormalize — a plain element-wise mean would let a larger-magnitude
    /// sample silently dominate.
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let count = Float(vectors.count)
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            let normalized = l2Normalized(vector)
            for i in 0..<normalized.count { sum[i] += normalized[i] }
        }
        let mean = sum.map { $0 / count }
        return l2Normalized(mean)
    }
}
