import Foundation

/// The shared document API. Rig manuals, trip paperwork, reservation confirmations, and
/// backup/recovery all use this contract instead of feature-specific attachment storage.
///
/// Rules every implementation follows:
/// - Uploaded bytes are stored and returned exactly; reads verify them against the SHA-256
///   recorded when they were added.
/// - Links must be HTTPS and stay online-only until `attachContent` imports their bytes.
/// - Sensitive categories are end-to-end encrypted, and a document's protection is never lowered.
/// - Deletion happens only through `deleteDocument`, never as a side effect of other edits.
public protocol DocumentRepository: Sendable {
    /// Active documents, newest first. `nil` lists every owner (for example, for backup).
    func documents(ownedBy owner: DocumentOwner?) async throws -> [ManagedDocument]
    func document(id: UUID) async throws -> ManagedDocument?
    @discardableResult func addDocument(_ draft: DocumentDraft) async throws -> ManagedDocument
    /// Raising protection (for example by choosing a sensitive category) re-encrypts the file.
    @discardableResult func updateDocument(id: UUID, metadata: DocumentMetadata) async throws -> ManagedDocument
    /// Explicitly import a linked document's contents so it opens offline. The link is kept.
    @discardableResult func attachContent(toDocument id: UUID, source: DocumentByteSource, filename: String) async throws -> ManagedDocument
    /// Verified original bytes in memory. Prefer `exportContents` for large files.
    /// Throws `linkOnly`, `contentNotDownloaded`, or `contentIntegrity`.
    func contents(ofDocument id: UUID) async throws -> DocumentContents
    /// Writes the verified original bytes to `url` in chunks. On any failure nothing is left at `url`.
    @discardableResult func exportContents(ofDocument id: UUID, to url: URL) async throws -> DocumentFile
    func deleteDocument(id: UUID) async throws
}

public extension DocumentRepository {
    @discardableResult
    func attachContent(toDocument id: UUID, bytes: Data, filename: String) async throws -> ManagedDocument {
        try await attachContent(toDocument: id, source: .data(bytes), filename: filename)
    }
}

extension DocumentSource {
    /// The byte source for an upload, or nil for a link.
    public var byteSource: (source: DocumentByteSource, filename: String)? {
        switch self {
        case .file(let data, let filename): (.data(data), filename)
        case .fileAt(let url, let filename): (.file(url), filename)
        case .link: nil
        }
    }
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
        if case .link(let url) = draft.source { document.link = try DocumentPolicy.validatedLink(url) }
        if let upload = draft.source.byteSource {
            document.file = try DocumentPolicy.inspect(upload.source, filename: upload.filename)
            bytes[draft.id] = try Self.read(upload.source); document.isContentAvailable = true
        }
        stored[draft.id] = document
        return document
    }

    public func updateDocument(id: UUID, metadata: DocumentMetadata) throws -> ManagedDocument {
        guard var document = stored[id] else { throw DocumentError.documentNotFound }
        var validated = try DocumentPolicy.validated(metadata)
        validated.protection = max(validated.protection, document.metadata.protection)
        document.metadata = validated; document.updatedAt = now()
        stored[id] = document
        return document
    }

    public func attachContent(toDocument id: UUID, source: DocumentByteSource, filename: String) throws -> ManagedDocument {
        guard var document = stored[id] else { throw DocumentError.documentNotFound }
        guard document.link != nil else { throw DocumentError.notALink }
        document.file = try DocumentPolicy.inspect(source, filename: filename)
        document.isContentAvailable = true; document.updatedAt = now()
        bytes[id] = try Self.read(source); stored[id] = document
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

    public func exportContents(ofDocument id: UUID, to url: URL) throws -> DocumentFile {
        let contents = try contents(ofDocument: id)
        try contents.bytes.write(to: url, options: .atomic)
        return contents.file
    }

    public func deleteDocument(id: UUID) throws {
        guard stored.removeValue(forKey: id) != nil else { throw DocumentError.documentNotFound }
        bytes[id] = nil
    }

    private static func read(_ source: DocumentByteSource) throws -> Data {
        var data = Data()
        try source.forEachChunk { data.append($0) }
        return data
    }
}
