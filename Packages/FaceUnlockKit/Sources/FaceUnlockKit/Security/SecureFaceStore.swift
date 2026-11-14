//
//  SecureFaceStore.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Low-level encrypted persistence for enrolled face identities — AES-GCM under the same session key
//  SecureCredentialManager uses for the Mac password. Only embeddings (512 floats) are stored, never images.
//  No plaintext fallback.
//

import Foundation

enum SecureFaceStoreError: LocalizedError {
    case sessionLocked

    var errorDescription: String? {
        switch self {
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID to access enrolled faces."
        }
    }
}

enum SecureFaceStore {
    /// Distinct extension so plaintext can never be mistaken for ciphertext. Folder is created 0700.
    private static var fileURL: URL {
        FaceUnlockEnvironment.storageDirectoryURL.appendingPathComponent("face-identities.enc")
    }

    /// True if a store exists on disk, regardless of whether the session is currently unlocked enough to read it.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Throws `.sessionLocked` rather than returning an empty array, so callers can distinguish "nothing enrolled"
    /// from "enrolled, but locked".
    static func load() throws -> [FaceIdentity] {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        guard let ciphertext = try? Data(contentsOf: fileURL) else { return [] }
        let plaintext = try SecureCredentialManager.decrypt(ciphertext)
        return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
    }

    static func save(_ identities: [FaceIdentity]) throws {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        let plaintext = try JSONEncoder().encode(identities)
        let ciphertext = try SecureCredentialManager.encrypt(plaintext)
        _ = FaceUnlockEnvironment.storageDirectory // ensure the 0700 folder exists
        try ciphertext.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
