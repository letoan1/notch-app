//
//  ArcFaceModelStore.swift
//  FaceUnlockKit
//
//  New in FaceUnlockKit (not in Glance). Finds the ArcFace model and compiles the .mlpackage at runtime with
//  `MLModel.compileModel(at:)`, because Command Line Tools ship no `coremlc` (Xcode normally does this at build time).
//
//  Cache policy (security-relevant): the compiled model decides whose face unlocks the Mac. A compiled copy in
//  Application Support is user-writable, unlike Glance's model inside the code-signed app bundle. The default
//  `.perLaunch` policy therefore recompiles from the bundled (signed) .mlpackage once per process instead of
//  trusting a file an earlier process — or any same-user process — could have swapped.
//

import Foundation
import CoreML
import CryptoKit

public enum ArcFaceModelCachePolicy: Sendable {
    /// Compile once per process into a fresh 0700 folder under Application Support; stale per-launch folders are
    /// deleted at the next launch. Default — never trusts a compiled model written by an earlier process.
    case perLaunch
    /// Reuse `ArcFace-<source digest>.mlmodelc` across launches. Faster cold start, but trusts a user-writable file.
    case persistent
}

enum ArcFaceModelStore {
    static let resourceBundleName = "FaceUnlockKit_FaceUnlockKit.bundle"
    /// ArcFace.mlpackage as shipped in the SwiftPM resource bundle, minus its extension (see Package.swift).
    static let packagedResourceName = "ArcFaceModel"
    nonisolated(unsafe) static var cachePolicy: ArcFaceModelCachePolicy = .perLaunch

    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiledThisProcess: URL?

    /// Last compile duration (seconds), nil if no compile happened in this process. Diagnostics only.
    nonisolated(unsafe) private(set) static var lastCompileSeconds: Double?

    /// Returns a loadable `.mlmodelc`, compiling the bundled `.mlpackage` if that's what was found.
    static func compiledModelURL() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let url = compiledThisProcess, FileManager.default.fileExists(atPath: url.path) { return url }

        let (source, searched) = locateModel()
        guard let source else { throw ArcFaceEmbedderError.modelNotFound(searched) }
        if source.pathExtension == "mlmodelc" {
            compiledThisProcess = source
            return source
        }

        let cacheRoot = FaceUnlockEnvironment.storageDirectory.appendingPathComponent("ModelCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default

        let destination: URL
        switch cachePolicy {
        case .persistent:
            let digest = try directoryDigest(source).prefix(16)
            destination = cacheRoot.appendingPathComponent("ArcFace-\(digest).mlmodelc", isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                compiledThisProcess = destination
                return destination
            }
        case .perLaunch:
            // Remove folders left by previous launches (they are never reused).
            if let stale = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) {
                for url in stale where url.lastPathComponent.hasPrefix("launch-") || url.lastPathComponent.hasPrefix("staging-") {
                    try? fm.removeItem(at: url)
                }
            }
            let dir = cacheRoot.appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            destination = dir.appendingPathComponent("ArcFace.mlmodelc", isDirectory: true)
        }

        // Core ML identifies a package by its `.mlpackage` extension; stage an extension-ful copy in a private folder.
        var compileSource = source
        var stagingDir: URL?
        if source.pathExtension != "mlpackage" {
            let dir = cacheRoot.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            compileSource = dir.appendingPathComponent("ArcFace.mlpackage", isDirectory: true)
            try fm.copyItem(at: source, to: compileSource)
            stagingDir = dir
        }
        defer { if let stagingDir { try? fm.removeItem(at: stagingDir) } }

        let started = Date()
        let temporary: URL
        do {
            temporary = try MLModel.compileModel(at: compileSource)
        } catch {
            throw ArcFaceEmbedderError.modelCompileFailed(error.localizedDescription)
        }
        lastCompileSeconds = Date().timeIntervalSince(started)

        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            // Moving out of the system temp dir failed — fall back to the temp location for this process.
            compiledThisProcess = temporary
            return temporary
        }
        compiledThisProcess = destination
        return destination
    }

    /// Search order: explicit `FaceUnlockConfiguration.modelURL`, the host app's own resources, then the SwiftPM
    /// resource bundle (next to the executable for `swift run`, or copied into Contents/Resources by the host).
    /// Deliberately avoids SwiftPM's generated `Bundle.module`, which `fatalError`s when the bundle isn't where
    /// it expects — a hand-assembled .app (like Notch's build.sh) would crash instead of failing closed.
    static func locateModel() -> (URL?, [String]) {
        var searched: [String] = []
        let fm = FileManager.default

        if let explicit = FaceUnlockEnvironment.configuration.modelURL {
            searched.append(explicit.path)
            if fm.fileExists(atPath: explicit.path) { return (explicit, searched) }
        }

        var bundles: [Bundle] = [Bundle.main]
        var candidateDirs: [URL] = []
        if let resources = Bundle.main.resourceURL { candidateDirs.append(resources) }
        candidateDirs.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { candidateDirs.append(exe) }
        for dir in candidateDirs {
            let url = dir.appendingPathComponent(resourceBundleName)
            if let bundle = Bundle(url: url) { bundles.append(bundle) }
        }

        for bundle in bundles {
            for ext in ["mlmodelc", "mlpackage"] {
                searched.append("\(bundle.bundlePath)/ArcFace.\(ext)")
                if let url = bundle.url(forResource: "ArcFace", withExtension: ext) { return (url, searched) }
            }
            // SwiftPM resource copy of the package, stored extension-less (see Package.swift).
            searched.append("\(bundle.bundlePath)/\(packagedResourceName)")
            if let url = bundle.url(forResource: packagedResourceName, withExtension: nil),
               fm.fileExists(atPath: url.appendingPathComponent("Manifest.json").path) {
                return (url, searched)
            }
        }
        return (nil, searched)
    }

    /// SHA-256 over every file (relative path + bytes), stable ordering.
    static func directoryDigest(_ root: URL) throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw ArcFaceEmbedderError.modelCompileFailed("can't enumerate \(root.path)")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
        let rootPath = root.standardizedFileURL.path
        var hasher = SHA256()
        for url in files.sorted(by: { $0.path < $1.path }) {
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: try Data(contentsOf: url, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
