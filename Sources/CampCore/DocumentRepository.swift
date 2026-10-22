import Foundation

/// The shared document API. Rig manuals, trip paperwork, reservation confirmations, and
/// backup/recovery all use this contract instead of feature-specific attachment storage.
///
/// Rules every implementation follows:
/// - Uploaded bytes are stored and returned exactly; `contents` verifies them against the
///   SHA-256 recorded when they were added.
/// - Links must be HTTPS and stay online-only until `attachContent` imports their bytes.
/// - Deletion happens only through `deleteDocument`, never as a side effect of other edits.
public protocol DocumentRepository: Sendable {
    /// Active documents, newest first. `nil` lists every owner (for example, for backup).
    func documents(ownedBy owner: DocumentOwner?) async throws -> [ManagedDocument]
    func document(id: UUID) async throws -> ManagedDocument?
    @discardableResult func addDocument(_ draft: DocumentDraft) async throws -> ManagedDocument
    @discardableResult func updateDocument(id: UUID, metadata: DocumentMetadata) async throws -> ManagedDocument
    /// Explicitly import a linked document's contents so it opens offline. The link is kept.
    @discardableResult func attachContent(toDocument id: UUID, bytes: Data, filename: String) async throws -> ManagedDocument
    /// Verified original bytes. Throws `linkOnly`, `contentNotDownloaded`, or `contentIntegrity`.
    func contents(ofDocument id: UUID) async throws -> DocumentContents
    func deleteDocument(id: UUID) async throws
}

/// Reference implementation for previews and tests. It applies the same policy as the
/// Core Data repository but keeps nothing on disk.
public actor InMemoryDocumentRepository: DocumentRepository {
    private var stored: [UUID: ManagedDocument] = [:]
    private var bytes: [UUID: Data] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// Simulates a synced record whose bytes have not arrived on this device.
    public func discardLocalContent(ofDocument id: UUID) {
        bytes[id] = nil
        stored[id]?.isContentAvailable = false
    }

    public func documents(ownedBy owner: DocumentOwner?) -> [ManagedDocument] {
        stored.values.filter { owner == nil || $0.owner == owner }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    public func document(id: UUID) -> ManagedDocument? { stored[id] }

    public func addDocument(_ draft: DocumentDraft) throws -> ManagedDocument {
        guard stored[draft.id] == nil else { throw DocumentError.duplicateDocument }
        let metadata = try DocumentPolicy.validated(draft.metadata)
        var document = ManagedDocument(id: draft.id, owner: draft.owner, metadata: metadata, createdAt: draft.createdAt,
                                       updatedAt: now(), isContentAvailable: false)
        switch draft.source {
        case .link(let url): document.link = try DocumentPolicy.validatedLink(url)
        case .file(let data, let filename):
            document.file = try DocumentPolicy.inspect(data, filename: filename)
            bytes[draft.id] = data; document.isContentAvailable = true
        }
        stored[draft.id] = document
        return document
    }

    public func updateDocument(id: UUID, metadata: DocumentMetadata) throws -> ManagedDocument {
        guard var document = stored[id] else { throw DocumentError.documentNotFound }
        document.metadata = try DocumentPolicy.validated(metadata); document.updatedAt = now()
        stored[id] = document
        return document
    }

    public func attachContent(toDocument id: UUID, bytes data: Data, filename: String) throws -> ManagedDocument {
        guard var document = stored[id] else { throw DocumentError.documentNotFound }
        guard document.link != nil else { throw DocumentError.notALink }
        document.file = try DocumentPolicy.inspect(data, filename: filename)
        document.isContentAvailable = true; document.updatedAt = now()
        bytes[id] = data; stored[id] = document
        return document
    }

    public func contents(ofDocument id: UUID) throws -> DocumentContents {
        guard let document = stored[id] else { throw DocumentError.documentNotFound }
        guard let file = document.file, let data = bytes[id] else {
            throw document.file == nil ? DocumentError.linkOnly : DocumentError.contentNotDownloaded
        }
        guard DocumentDigest.sha256(data) == file.checksum else { throw DocumentError.contentIntegrity }
        return DocumentContents(file: file, bytes: data)
    }

    public func deleteDocument(id: UUID) throws {
        guard stored.removeValue(forKey: id) != nil else { throw DocumentError.documentNotFound }
        bytes[id] = nil
    }
}
