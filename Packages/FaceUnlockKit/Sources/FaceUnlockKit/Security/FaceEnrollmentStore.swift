//
//  FaceEnrollmentStore.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Persisted encrypted under the same Touch-ID-gated session key as the stored Mac password (see SecureFaceStore);
//  `isLocked`/`reloadIfUnlocked()` distinguish "locked" from "nothing enrolled."
//  Port notes: `@Observable` → `ObservableObject` + `@Published`; no longer a singleton (owned by FaceUnlockService);
//  Face Lab's single-sample `addSample` dropped.
//

import Foundation
import Combine

struct FaceSample: Codable, Equatable {
    let embedding: [Float]
    /// Which guided-enrollment pose this came from (`EnrollmentPose.name`), or nil for untagged captures.
    let pose: String?
    let capturedAt: Date
    /// Vision's capture-quality score (0...1), or nil if unavailable.
    let quality: Float?
}

struct FaceIdentity: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var samples: [FaceSample]
    /// Which `FaceEmbedder.modelIdentifier` produced these samples — different models' embeddings live in unrelated
    /// vector spaces. See `isStale(comparedTo:)`.
    var modelIdentifier: String
    var embeddingDimension: Int
    var createdAt: Date
    /// Turning off keeps the enrollment intact but excludes it from `activeIdentities`, which unlock scores against.
    var isEnabled: Bool

    init(
        id: UUID,
        name: String,
        samples: [FaceSample],
        modelIdentifier: String,
        embeddingDimension: Int,
        createdAt: Date,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.samples = samples
        self.modelIdentifier = modelIdentifier
        self.embeddingDimension = embeddingDimension
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    /// Hand-written so `isEnabled` defaults to `true` when absent — a synthesized decoder would throw on a missing
    /// key and, since the whole store decodes as one array, lose every identity in it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        samples = try container.decode([FaceSample].self, forKey: .samples)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        embeddingDimension = try container.decode(Int.self, forKey: .embeddingDimension)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// The single vector actually compared against at recognition time.
    var template: [Float]? {
        FaceEmbedding.average(samples.map(\.embedding))
    }

    /// True if samples came from a different embedder than the one currently active — should prompt re-enrollment.
    func isStale(comparedTo embedder: FaceEmbedder) -> Bool {
        modelIdentifier != embedder.modelIdentifier
    }
}

enum FaceEnrollmentStoreError: LocalizedError {
    case storeUnreadable
    case emptyName
    case nameTaken(String)
    case noSamples

    var errorDescription: String? {
        switch self {
        case .storeUnreadable:
            return "Your enrolled faces couldn't be read, so nothing was saved — writing now would overwrite them."
        case .emptyName:
            return "Enter a name."
        case .nameTaken(let name):
            return "A face named \"\(name)\" is already enrolled."
        case .noSamples:
            return "No face samples were captured."
        }
    }
}

@MainActor
final class FaceEnrollmentStore: ObservableObject {
    @Published private(set) var identities: [FaceIdentity] = []
    /// True until a successful load — distinguishes "nothing enrolled yet" from "locked, needs Touch ID."
    @Published private(set) var isLocked = true
    /// Non-nil when unlocked but the encrypted store still couldn't be read (decrypt/decode failure, not a missing key).
    @Published private(set) var loadFailure: String?

    /// False until a load succeeds. Guards `persist()` so an unreadable store is never overwritten by an empty array.
    private var hasLoadedSuccessfully = false
    private var sessionObserver: NSObjectProtocol?

    /// Everyone the user hasn't switched off — what unlock actually scores against.
    var activeIdentities: [FaceIdentity] {
        identities.filter(\.isEnabled)
    }

    init() {
        reloadIfUnlocked()
        // Reload whenever the session key changes, regardless of call site.
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadIfUnlocked()
            }
        }
    }

    deinit {
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
    }

    /// Re-attempts loading from encrypted storage. Leaves `isLocked = true` if the session isn't unlocked.
    func reloadIfUnlocked() {
        guard SecureCredentialManager.isSessionUnlocked else {
            identities = []
            isLocked = true
            return
        }
        do {
            identities = try SecureFaceStore.load()
            hasLoadedSuccessfully = true
            loadFailure = nil
        } catch {
            // Deliberately not `(try? load()) ?? []` — a store we couldn't read isn't an empty store.
            identities = []
            hasLoadedSuccessfully = false
            loadFailure = error.localizedDescription
        }
        isLocked = false
    }

    /// Commits a whole guided enrollment in a single write. When `existingID` names a known identity, its samples are
    /// replaced wholesale (a recapture is a redo, not an append) and it can be renamed since matching is by id.
    @discardableResult
    func commitEnrollment(
        replacing existingID: UUID?,
        name: String,
        samples: [FaceSample],
        embedder: FaceEmbedder
    ) throws -> FaceIdentity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FaceEnrollmentStoreError.emptyName }
        guard !samples.isEmpty else { throw FaceEnrollmentStoreError.noSamples }
        guard hasLoadedSuccessfully else { throw FaceEnrollmentStoreError.storeUnreadable }
        guard !nameIsTaken(trimmed, excluding: existingID) else { throw FaceEnrollmentStoreError.nameTaken(trimmed) }

        // Local copy, only assigned once the write succeeds.
        var updated = identities
        let committed: FaceIdentity
        if let existingID, let index = updated.firstIndex(where: { $0.id == existingID }) {
            updated[index].name = trimmed
            updated[index].samples = samples
            updated[index].modelIdentifier = embedder.modelIdentifier
            updated[index].embeddingDimension = embedder.embeddingDimension
            committed = updated[index]
        } else {
            committed = FaceIdentity(
                id: UUID(),
                name: trimmed,
                samples: samples,
                modelIdentifier: embedder.modelIdentifier,
                embeddingDimension: embedder.embeddingDimension,
                createdAt: Date()
            )
            updated.append(committed)
        }
        try SecureFaceStore.save(updated)
        identities = updated
        return committed
    }

    /// Case- and diacritic-insensitive: "alex"/"Alex"/"Álex" are one person to the user.
    func nameIsTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return identities.contains {
            $0.id != id
                && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Reverts the in-memory flag if the encrypted write fails.
    func setEnabled(_ isEnabled: Bool, for identityID: UUID) throws {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        let previous = identities[index].isEnabled
        guard previous != isEnabled else { return }
        identities[index].isEnabled = isEnabled
        do {
            try persist()
        } catch {
            identities[index].isEnabled = previous
            throw error
        }
    }

    func delete(id: UUID) throws {
        let previous = identities
        identities.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            identities = previous
            throw error
        }
    }

    /// Removes the file outright (rather than writing an empty array).
    func deleteAll() {
        identities.removeAll()
        SecureFaceStore.deleteAll()
        loadFailure = nil
        hasLoadedSuccessfully = SecureCredentialManager.isSessionUnlocked
    }

    private func persist() throws {
        guard hasLoadedSuccessfully else {
            throw FaceEnrollmentStoreError.storeUnreadable
        }
        try SecureFaceStore.save(identities)
    }
}
