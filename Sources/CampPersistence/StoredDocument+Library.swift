#if canImport(SwiftData)
import Foundation
import SwiftData
import DocumentVault

/// The document vault: original bytes are stored exactly and verified by SHA-256 on every read;
/// sensitive types are always end-to-end encrypted; protection is never lowered.
public extension StoredDocument {
    var category: DocumentCategory { DocumentCategory(rawValue: categoryValue) }
    /// A value from a newer app version is treated as the stronger protection.
    var protection: DocumentProtection { DocumentProtection(rawValue: protectionValue) ?? .endToEnd }
    var linkURL: URL? { link.flatMap(URL.init(string:)) }

    var metadata: DocumentMetadata {
        DocumentMetadata(title: title, category: category, notes: notes, issuedOn: issuedOn, expiresOn: expiresOn, protection: protection)
    }

    /// The original file this document holds, whether or not its bytes are on this device yet.
    var file: DocumentFile? {
        guard let checksum, let type = contentTypeValue.flatMap(DocumentContentType.init(rawValue:)), let byteCount else { return nil }
        return DocumentFile(filename: filename ?? "Document.\(type.fileExtension)", contentType: type, byteCount: byteCount, checksum: checksum)
    }

    var availability: DocumentAvailability {
        guard let checksum else { return .onlineOnly }
        return content?.checksum == checksum && content?.bytes != nil ? .offline : .awaitingDownload
    }

    /// Adds a file (`contents` with its inspected description) or an `https` link.
    @discardableResult
    static func add(_ metadata: DocumentMetadata, contents: (bytes: Data, file: DocumentFile)? = nil, link: URL? = nil,
                    rig: Rig? = nil, trip: Trip? = nil, in context: ModelContext) throws -> StoredDocument {
        let metadata = try DocumentPolicy.validated(metadata)
        let link = try link.map(DocumentPolicy.validatedLink)
        guard contents != nil || link != nil else { throw DocumentError.emptyFile }
        let document = StoredDocument()
        context.insert(document)
        document.apply(metadata)
        document.link = link?.absoluteString
        document.rig = rig; document.trip = trip
        if let contents { try document.store(contents.bytes, file: contents.file) }
        return document
    }

    /// Raising protection (for example by choosing a sensitive type) re-encrypts the stored file.
    func update(_ metadata: DocumentMetadata) throws {
        var metadata = try DocumentPolicy.validated(metadata)
        metadata.protection = max(metadata.protection, protection)
        if metadata.protection > protection, let file {
            guard availability == .offline else { throw DocumentError.protectionNeedsContent }
            let plaintext = try contents()
            protectionValue = metadata.protection.rawValue
            try store(plaintext, file: file)
        }
        apply(metadata)
        updatedAt = .now
    }

    /// Explicitly saves a link's contents so it opens offline. The link is kept.
    func attach(_ bytes: Data, file: DocumentFile) throws {
        try store(bytes, file: file)
        updatedAt = .now
    }

    /// The verified original bytes. Throws `linkOnly`, `contentNotDownloaded`, or `contentIntegrity`.
    func contents() throws -> Data {
        guard let file else { throw DocumentError.linkOnly }
        guard let content, content.checksum == file.checksum, let stored = content.bytes else { throw DocumentError.contentNotDownloaded }
        return try DocumentSealing.open(stored, key: content.key, documentID: documentID, expecting: file)
    }

    private func store(_ bytes: Data, file: DocumentFile) throws {
        guard DocumentDigest.sha256(bytes) == file.checksum, bytes.count == file.byteCount else { throw DocumentError.contentIntegrity }
        let sealed = try DocumentSealing.seal(bytes, protection: protection, documentID: documentID)
        let content = self.content ?? DocumentContent()
        if self.content == nil { modelContext?.insert(content); self.content = content }
        content.bytes = sealed.bytes; content.key = sealed.key; content.checksum = file.checksum
        filename = file.filename; contentTypeValue = file.contentType.rawValue
        byteCount = file.byteCount; checksum = file.checksum
    }

    private func apply(_ metadata: DocumentMetadata) {
        title = metadata.title; categoryValue = metadata.category.rawValue; notes = metadata.notes
        issuedOn = metadata.issuedOn; expiresOn = metadata.expiresOn
        protectionValue = max(metadata.protection, protection).rawValue
    }
}
#endif
