//
//  ArcFaceEmbedder.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt. Model: InsightFace ArcFace w600k_mbf — see NOTICE.md (non-commercial research license).
//
//  Requires a canonically-aligned 112x112 input (see FaceAligner).
//  Port note: Glance loads an Xcode-compiled ArcFace.mlmodelc from Bundle.main. Without Xcode there is no
//  coremlc, so the .mlpackage is compiled at runtime by `ArcFaceModelStore`.
//

import Foundation
import CoreML
import CoreGraphics
import CoreVideo

public enum ArcFaceEmbedderError: LocalizedError {
    case modelNotFound([String])
    case modelCompileFailed(String)
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case unexpectedInputSize(got: (Int, Int), expected: Int)
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let searched):
            return "ArcFace model (ArcFace.mlpackage / ArcFace.mlmodelc) not found. Searched: \(searched.joined(separator: ", "))"
        case .modelCompileFailed(let detail):
            return "Failed to compile the ArcFace Core ML model: \(detail)"
        case .modelLoadFailed(let detail):
            return "Failed to load the ArcFace Core ML model: \(detail)"
        case .pixelBufferCreationFailed:
            return "Couldn't prepare the aligned face image for Core ML."
        case .unexpectedInputSize(let got, let expected):
            return "ArcFaceEmbedder expects a \(expected)x\(expected) aligned image, got \(got.0)x\(got.1)."
        case .unexpectedOutput(let detail):
            return "ArcFace model produced an unexpected output: \(detail)"
        }
    }
}

final class ArcFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    let name = "ArcFace (w600k_mbf)"
    /// Same identifier as Glance so embeddings are comparable with the same model.
    let modelIdentifier = "arcface-w600k_mbf-v1"
    let embeddingDimension = 512
    let requiresAlignment = true

    static let inputSize = FaceAligner.outputSize
    private static let inputName = "input_image"
    private static let outputName = "embedding"

    // Loaded once and reused — model load dominates a single inference.
    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool
    /// `MLModel.prediction` is documented thread-safe, but the pool + render are serialized to keep it simple.
    private let predictLock = NSLock()

    /// Throws if the model can't be located/compiled/loaded — callers must treat that as "face unlock unavailable".
    init(computeUnits: MLComputeUnits = .all) throws {
        let compiledURL = try ArcFaceModelStore.compiledModelURL()

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        do {
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw ArcFaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }

        guard let pool = Self.makePixelBufferPool(size: Self.inputSize) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        pixelBufferPool = pool
    }

    /// Input/output feature names + shapes, for diagnostics.
    var modelDescriptionSummary: String {
        let d = model.modelDescription
        let inputs = d.inputDescriptionsByName.map { "\($0.key): \($0.value.type.rawValue)" }.sorted()
        let outputs = d.outputDescriptionsByName.map { "\($0.key): \($0.value.multiArrayConstraint?.shape ?? [])" }.sorted()
        return "inputs=\(inputs) outputs=\(outputs)"
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// Synchronous/blocking — run off the main thread.
    func embedding(for face: CGImage) throws -> [Float] {
        guard face.width == Self.inputSize, face.height == Self.inputSize else {
            throw ArcFaceEmbedderError.unexpectedInputSize(got: (face.width, face.height), expected: Self.inputSize)
        }
        predictLock.lock()
        defer { predictLock.unlock() }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(face, into: pixelBuffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw ArcFaceEmbedderError.unexpectedOutput("no '\(Self.outputName)' output found")
        }
        guard multiArray.count == embeddingDimension else {
            throw ArcFaceEmbedderError.unexpectedOutput("expected \(embeddingDimension) floats, got \(multiArray.count)")
        }

        let raw = Self.floatVector(from: multiArray)
        return FaceEmbedding.l2Normalized(raw)
    }

    private static func render(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ArcFaceEmbedderError.pixelBufferCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// `MLMultiArray` storage isn't guaranteed to be a flat, stride-1 buffer, so this indexes via the array's own subscript.
    private static func floatVector(from array: MLMultiArray) -> [Float] {
        var result = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count {
            result[i] = array[i].floatValue
        }
        return result
    }
}
