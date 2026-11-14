//
//  FaceUnlockDiagnostics.swift
//  FaceUnlockKit
//
//  Camera-free, Keychain-free checks for build/CI: proves the bundled ArcFace model can be found, compiled at
//  runtime and run, and exercises the pure liveness evaluator.
//

import Foundation
import CoreGraphics

public struct ModelSelfTestResult: Sendable {
    public let modelPath: String
    public let compiledPath: String
    /// nil when an already-compiled .mlmodelc was found (nothing to compile).
    public let compileSeconds: Double?
    public let loadSeconds: Double
    public let embeddingDimension: Int
    public let embeddingNorm: Float
    /// Cosine similarity between embeddings of two different synthetic images (sanity: < 1).
    public let crossSimilarity: Float
    /// Cosine similarity between two runs on the same image (sanity: ≈ 1).
    public let repeatSimilarity: Float
    public let modelDescription: String
}

public enum FaceUnlockDiagnostics {
    /// Locates + compiles + loads ArcFace and embeds two synthetic 112x112 images. Blocking.
    public static func runModelSelfTest(
        configuration: FaceUnlockConfiguration? = nil,
        cachePolicy: ArcFaceModelCachePolicy = .perLaunch
    ) throws -> ModelSelfTestResult {
        if let configuration { FaceUnlockEnvironment.configuration = configuration }
        ArcFaceModelStore.cachePolicy = cachePolicy

        let (located, searched) = ArcFaceModelStore.locateModel()
        guard let located else { throw ArcFaceEmbedderError.modelNotFound(searched) }

        let started = Date()
        let embedder = try ArcFaceEmbedder()
        let loadSeconds = Date().timeIntervalSince(started)
        let compiled = try ArcFaceModelStore.compiledModelURL()

        guard let a = syntheticImage(seed: 1), let b = syntheticImage(seed: 2) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        let ea = try embedder.embedding(for: a)
        let ea2 = try embedder.embedding(for: a)
        let eb = try embedder.embedding(for: b)
        let norm = sqrt(ea.reduce(Float(0)) { $0 + $1 * $1 })

        return ModelSelfTestResult(
            modelPath: located.path,
            compiledPath: compiled.path,
            compileSeconds: ArcFaceModelStore.lastCompileSeconds,
            loadSeconds: loadSeconds,
            embeddingDimension: ea.count,
            embeddingNorm: norm,
            crossSimilarity: FaceEmbedding.cosineSimilarity(ea, eb),
            repeatSimilarity: FaceEmbedding.cosineSimilarity(ea, ea2),
            modelDescription: embedder.modelDescriptionSummary
        )
    }

    /// Drives the real `LivenessEvaluator` with synthetic readings: a glare deny cue must override everything,
    /// Light mode must auto-confirm after its minimum frames, Heavy mode must wait for a confirm cue.
    public static func runLivenessSelfTest() -> [String: Bool] {
        var results: [String: Bool] = [:]

        var light = LivenessEvaluator(mode: .light)
        var snapshot = LivenessSnapshot.empty
        for _ in 0..<3 { snapshot = light.observe([:]) }
        results["light auto-confirms after 3 frames"] = snapshot.decision.isConfirmed

        var heavy = LivenessEvaluator(mode: .heavy)
        for _ in 0..<5 { snapshot = heavy.observe([:]) }
        results["heavy stays pending without a confirm cue"] = snapshot.decision == .pending
        snapshot = heavy.observe([.blink: CueReading(level: 1, confidence: 1)])
        results["heavy confirms on blink"] = snapshot.decision == .confirmed(by: .blink)

        var spoof = LivenessEvaluator(mode: .light)
        for _ in 0..<3 { snapshot = spoof.observe([.glossGlare: CueReading(level: 0.9, confidence: 1)]) }
        results["glare deny overrides light confirmation"] = snapshot.decision == .denied(by: .glossGlare)
        return results
    }

    private static func syntheticImage(seed: Int) -> CGImage? {
        let size = ArcFaceEmbedder.inputSize
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Crude "face": skin-tone background, two eyes, nose, mouth — enough to exercise the model, not to recognize.
        context.setFillColor(CGColor(red: 0.85, green: 0.7, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        let shift = CGFloat(seed * 6)
        context.fillEllipse(in: CGRect(x: 30 + shift, y: 52, width: 14, height: 8))
        context.fillEllipse(in: CGRect(x: 66 - shift, y: 52, width: 14, height: 8))
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 40, y: 18 + shift, width: 32, height: 6))
        context.setFillColor(CGColor(red: 0.75, green: 0.55, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 52, y: 34, width: 8, height: 16))
        return context.makeImage()
    }
}
