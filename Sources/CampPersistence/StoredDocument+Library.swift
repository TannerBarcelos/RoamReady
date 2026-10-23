#if canImport(SwiftData)
import Foundation
import SwiftData
import DocumentVault

/// Models own relationships and metadata; Apple owns file storage, encryption, and transfer.
public extension StoredDocument {
    var category: DocumentCategory { DocumentCategory(rawValue: categoryValue) }
    var protection: DocumentProtection { DocumentProtection(rawValue: protectionValue) ?? .endToEnd }
    var linkURL: URL? { link.flatMap(URL.init(string:)) }

    var metadata: DocumentMetadata {
        DocumentMetadata(title: title, category: category, notes: notes, issuedOn: issuedOn, expiresOn: expiresOn, protection: protection)
    }

    var file: DocumentFile? {
        guard let checksum, let type = contentTypeValue.flatMap(DocumentContentType.init(rawValue:)), let byteCount else { return nil }
        return DocumentFile(filename: filename ?? "Document.\(type.fileExtension)", contentType: type, byteCount: byteCount, checksum: checksum)
    }

    var availability: DocumentAvailability {
        guard let checksum else { return .onlineOnly }
        guard let content, content.checksum == checksum else { return .awaitingDownload }
        if content.protectedBytes != nil { return .offline }
        // Legacy ciphertext and its key may arrive separately. Never present it as ready early.
        return content.bytes != nil && (protection != .endToEnd || content.key != nil) ? .offline : .awaitingDownload
    }

    @discardableResult
    static func add(_ metadata: DocumentMetadata, contents: DocumentPayload? = nil, link: URL? = nil,
                    rig: Rig? = nil, trip: Trip? = nil, in context: ModelContext) throws -> StoredDocument {
        let metadata = try DocumentPolicy.validated(metadata)
        let link = try link.map(DocumentPolicy.validatedLink)
        guard contents != nil || link != nil else { throw DocumentError.emptyFile }
        let document = StoredDocument()
        context.insert(document)
        document.apply(metadata)
        document.protectionValue = DocumentProtection.endToEnd.rawValue
        document.link = link?.absoluteString
        document.rig = rig; document.trip = trip
        if let contents { document.store(contents) }
        return document
    }

    /// Editing labels or categories doesn't download, decrypt, or rewrite attachment bytes.
    func update(_ metadata: DocumentMetadata) throws {
        apply(try DocumentPolicy.validated(metadata))
        updatedAt = .now
    }

    func attach(_ contents: DocumentPayload) {
        store(contents)
        updatedAt = .now
    }

    /// Capture model values on its context's actor; verify/decrypt/write the snapshot elsewhere.
    func contentSnapshot() throws -> DocumentContentSnapshot {
        guard let file else { throw DocumentError.linkOnly }
        guard let content, content.checksum == file.checksum else { throw DocumentError.contentNotDownloaded }
        if let bytes = content.protectedBytes {
            return DocumentContentSnapshot(bytes: bytes, key: nil, documentID: documentID, file: file)
        }
        guard let bytes = content.bytes, protection != .endToEnd || content.key != nil else { throw DocumentError.contentNotDownloaded }
        return DocumentContentSnapshot(bytes: bytes, key: content.key, documentID: documentID, file: file)
    }

    /// Synchronous access for package/export callers. UI previews use an off-actor snapshot.
    func contents() throws -> Data { try contentSnapshot().verifiedBytes() }

    private func store(_ contents: DocumentPayload) {
        let content = self.content ?? DocumentContent()
        if self.content == nil { modelContext?.insert(content); self.content = content }
        content.protectedBytes = contents.bytes
        content.bytes = nil; content.key = nil
        content.checksum = contents.file.checksum
        filename = contents.file.filename; contentTypeValue = contents.file.contentType.rawValue
        byteCount = contents.file.byteCount; checksum = contents.file.checksum
        protectionValue = DocumentProtection.endToEnd.rawValue
    }

    private func apply(_ metadata: DocumentMetadata) {
        title = metadata.title; categoryValue = metadata.category.rawValue; notes = metadata.notes
        issuedOn = metadata.issuedOn; expiresOn = metadata.expiresOn
        // Preserve the format marker on legacy content until its file is explicitly replaced.
    }
}

public struct DocumentContentSnapshot: Sendable {
    public let bytes: Data
    public let key: Data?
    public let documentID: UUID
    public let file: DocumentFile

    public func verifiedBytes() throws -> Data {
        try LegacyDocumentSealing.open(bytes, key: key, documentID: documentID, expecting: file)
    }
}
#endif
