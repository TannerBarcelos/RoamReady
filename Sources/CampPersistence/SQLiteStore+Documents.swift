#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CryptoKit
import CampCore

/// Core Data document vault. Metadata (`RR_document`) and original bytes
/// (`RR_documentContent.bytes`, external storage allowed) mirror through the same
/// NSPersistentCloudKitContainer as the rest of the library. No custom transfer queue exists.
///
/// Large files never pass through memory as a whole in this code: uploads are hashed and, when
/// protected, encrypted in chunks into a staging file, then handed to Core Data as memory-mapped
/// data. Exports decrypt and verify chunk by chunk into a file. How Core Data itself buffers
/// external binary values is up to Core Data.
extension SQLiteStore: DocumentRepository {
    public func documents(ownedBy owner: DocumentOwner?) async throws -> [ManagedDocument] {
        try await context.perform { [self] in
            context.refreshAllObjects()
            var predicate: NSPredicate?
            if let owner { predicate = NSPredicate(format: "ownerKind == %@ AND ownerID == %@", owner.kind.rawValue, owner.id.uuidString) }
            let available = try availableContent()
            return try activeDocumentRows(predicate).compactMap { makeDocument($0, available: available) }
                .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        }
    }

    public func document(id: UUID) async throws -> ManagedDocument? {
        try await context.perform { [self] in
            context.refreshAllObjects()
            return try activeDocumentRow(id).flatMap { makeDocument($0, available: try availableContent(documentID: id)) }
        }
    }

    @discardableResult
    public func addDocument(_ draft: DocumentDraft) async throws -> ManagedDocument {
        let metadata = try DocumentPolicy.validated(draft.metadata)
        var link: URL?
        if case .link(let url) = draft.source { link = try DocumentPolicy.validatedLink(url) }
        // Hash and encrypt before entering the shared context so slow work never blocks it.
        let staged = try draft.source.byteSource.map { upload in
            try stageContent(upload.source, file: DocumentPolicy.inspect(upload.source, filename: upload.filename),
                             documentID: draft.id, protection: metadata.protection)
        }
        defer { staged?.discard() }
        return try await context.perform { [self] in
            do {
                // Tombstoned identifiers are never reused.
                guard try documentRows(draft.id).isEmpty else { throw DocumentError.duplicateDocument }
                let row = insertRow(ManagedStoreModel.documentEntity, key: documentKey(draft.id))
                row.setValue(draft.id.uuidString, forKey: "id")
                row.setValue(draft.owner.kind.rawValue, forKey: "ownerKind"); row.setValue(draft.owner.id.uuidString, forKey: "ownerID")
                row.setValue(draft.createdAt.timeIntervalSinceReferenceDate, forKey: "createdAt")
                row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                apply(metadata, to: row)
                row.setValue(link?.absoluteString, forKey: "linkURL")
                if let staged { insertContent(staged, documentID: draft.id, metadataRow: row) }
                try context.save()
                return try makeDocument(row, available: availableContent(documentID: draft.id)).unwrapped()
            } catch { context.rollback(); throw error }
        }
    }

    @discardableResult
    public func updateDocument(id: UUID, metadata: DocumentMetadata) async throws -> ManagedDocument {
        var validated = try DocumentPolicy.validated(metadata)
        guard let current = try await document(id: id) else { throw DocumentError.documentNotFound }
        // Protection is only ever raised. Raising it re-encrypts the stored file.
        validated.protection = max(validated.protection, current.metadata.protection)
        var staged: StagedContent?
        if validated.protection > current.metadata.protection, let file = current.file {
            guard current.isContentAvailable else { throw DocumentError.protectionNeedsContent }
            let plaintext = stagingURL()
            defer { try? FileManager.default.removeItem(at: plaintext) }
            try await exportContents(ofDocument: id, to: plaintext)
            staged = try stageContent(.file(plaintext), file: file, documentID: id, protection: validated.protection)
        }
        defer { staged?.discard() }
        let replacement = staged, finalMetadata = validated
        return try await context.perform { [self] in
            do {
                guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
                if let replacement {
                    // The file must not have changed since it was read for re-encryption.
                    guard row.value(forKey: "checksum") as? String == replacement.file.checksum else { throw DocumentError.contentIntegrity }
                    for old in try contentRows(documentID: id) { context.delete(old) }
                    insertContent(replacement, documentID: id, metadataRow: row)
                }
                apply(finalMetadata, to: row)
                row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                if context.hasChanges { try context.save() }
                return try makeDocument(row, available: availableContent(documentID: id)).unwrapped()
            } catch { context.rollback(); throw error }
        }
    }

    @discardableResult
    public func attachContent(toDocument id: UUID, source: DocumentByteSource, filename: String) async throws -> ManagedDocument {
        let file = try DocumentPolicy.inspect(source, filename: filename)
        guard let current = try await document(id: id) else { throw DocumentError.documentNotFound }
        guard current.link != nil else { throw DocumentError.notALink }
        let staged = try stageContent(source, file: file, documentID: id, protection: current.metadata.protection)
        defer { staged.discard() }
        return try await context.perform { [self] in
            do {
                guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
                // Re-importing a link deliberately replaces its previous imported copy.
                for old in try contentRows(documentID: id) { context.delete(old) }
                insertContent(staged, documentID: id, metadataRow: row)
                row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                try context.save()
                return try makeDocument(row, available: availableContent(documentID: id)).unwrapped()
            } catch { context.rollback(); throw error }
        }
    }

    public func contents(ofDocument id: UUID) async throws -> DocumentContents {
        let (file, candidates) = try await contentCandidates(id)
        for candidate in candidates {
            var bytes = Data()
            if (try? verify(candidate, file: file, documentID: id, into: { bytes.append($0) })) != nil {
                return DocumentContents(file: file, bytes: bytes)
            }
        }
        throw candidates.isEmpty ? DocumentError.contentNotDownloaded : DocumentError.contentIntegrity
    }

    @discardableResult
    public func exportContents(ofDocument id: UUID, to url: URL) async throws -> DocumentFile {
        let (file, candidates) = try await contentCandidates(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for candidate in candidates {
            // Write beside the destination; only a fully verified file is moved into place.
            let partial = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
            do {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: partial)
                do { try verify(candidate, file: file, documentID: id, into: { try handle.write(contentsOf: $0) }); try handle.close() }
                catch { try? handle.close(); throw error }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.moveItem(at: partial, to: url)
                return file
            } catch DocumentError.contentIntegrity {
                try? FileManager.default.removeItem(at: partial)
            } catch {
                try? FileManager.default.removeItem(at: partial); throw error
            }
        }
        throw candidates.isEmpty ? DocumentError.contentNotDownloaded : DocumentError.contentIntegrity
    }

    public func deleteDocument(id: UUID) async throws {
        try await context.perform { [self] in
            do {
                let rows = try documentRows(id)
                guard rows.contains(where: { $0.value(forKey: "removed") as? Bool != true }) else { throw DocumentError.documentNotFound }
                // Keep an identity-only tombstone so a stale device cannot resurrect it, and drop
                // personal metadata. Content rows (bytes and keys) are removed to release storage.
                for row in rows {
                    row.setValue(true, forKey: "removed")
                    for field in ["title", "notes", "linkURL", "filename", "checksum", "contentType", "category"] { row.setValue(nil, forKey: field) }
                    row.setValue(nil, forKey: "byteCount"); row.setValue(nil, forKey: "issuedOn"); row.setValue(nil, forKey: "expiresOn")
                    row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                }
                for content in try contentRows(documentID: id) { context.delete(content) }
                try context.save()
            } catch { context.rollback(); throw error }
        }
    }

    // MARK: Staging (outside the context)

    /// Bytes ready to hand to Core Data. Protected bytes are already ciphertext.
    struct StagedContent: Sendable {
        let file: DocumentFile
        let bytes: Data
        let encryption: String?
        let key: Data?
        let stagingFile: URL?
        func discard() { if let stagingFile { try? FileManager.default.removeItem(at: stagingFile) } }
    }

    struct ContentCandidate: Sendable {
        let bytes: Data
        let encryption: String?
        let key: Data?
    }

    static let stagingDirectoryName = "DocumentStaging"
    private func stagingURL() -> URL {
        directory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true).appendingPathComponent(UUID().uuidString)
    }

    /// Re-reads the source while hashing (and encrypting when protected) and refuses it unless it
    /// is exactly the bytes that were inspected.
    private func stageContent(_ source: DocumentByteSource, file: DocumentFile, documentID: UUID, protection: DocumentProtection) throws -> StagedContent {
        switch protection {
        case .endToEnd:
            let key = DocumentCipher.newKey(), staging = stagingURL()
            do {
                let digest = try DocumentCipher.encrypt(source, to: staging, key: key, documentID: documentID)
                guard digest == file.checksum else { throw DocumentError.contentIntegrity }
                return StagedContent(file: file, bytes: try Data(contentsOf: staging, options: .mappedIfSafe), encryption: DocumentCipher.scheme,
                                     key: key.withUnsafeBytes { Data($0) }, stagingFile: staging)
            } catch { try? FileManager.default.removeItem(at: staging); throw error }
        case .standard:
            let bytes: Data
            switch source {
            case .data(let data): bytes = data
            // Mapped, so a large file is paged from disk rather than copied into memory.
            case .file(let url): bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            var hasher = DocumentHasher()
            try DocumentByteSource.data(bytes).forEachChunk { hasher.update($0) }
            guard bytes.count == file.byteCount, hasher.finalize() == file.checksum else { throw DocumentError.contentIntegrity }
            return StagedContent(file: file, bytes: bytes, encryption: nil, key: nil, stagingFile: nil)
        }
    }

    /// Streams verified plaintext into `sink`. Throws `contentIntegrity` unless every byte matches.
    private func verify(_ candidate: ContentCandidate, file: DocumentFile, documentID: UUID, into sink: (Data) throws -> Void) throws {
        var hasher = DocumentHasher(), count = 0
        func emit(_ chunk: Data) throws { hasher.update(chunk); count += chunk.count; try sink(chunk) }
        switch candidate.encryption {
        case nil: try DocumentByteSource.data(candidate.bytes).forEachChunk(emit)
        case DocumentCipher.scheme?:
            guard let key = candidate.key, key.count == 32 else { throw DocumentError.contentIntegrity }
            try DocumentCipher.decrypt(candidate.bytes, key: SymmetricKey(data: key), documentID: documentID, emit)
        default: throw DocumentError.contentIntegrity
        }
        guard count == file.byteCount, hasher.finalize() == file.checksum else { throw DocumentError.contentIntegrity }
    }

    private func contentCandidates(_ id: UUID) async throws -> (DocumentFile, [ContentCandidate]) {
        try await context.perform { [self] in
            context.refreshAllObjects()
            guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
            guard let file = makeDocument(row, available: [])?.file else { throw DocumentError.linkOnly }
            let candidates = try contentRows(documentID: id).filter { $0.value(forKey: "checksum") as? String == file.checksum }.compactMap { content -> ContentCandidate? in
                guard let bytes = content.value(forKey: "bytes") as? Data else { return nil }
                let candidate = ContentCandidate(bytes: bytes, encryption: content.value(forKey: "encryption") as? String,
                                                 key: content.value(forKey: "contentKey") as? Data)
                context.refresh(content, mergeChanges: false)
                return candidate
            }
            return (file, candidates)
        }
    }

    // MARK: Rows (call inside `context.perform`)

    private func documentKey(_ id: UUID) -> String { "document:\(id.uuidString)" }

    private func insertRow(_ entity: String, key: String) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        row.setValue(key, forKey: "key"); row.setValue(UUID().uuidString, forKey: "rowID")
        return row
    }

    private func rowIdentity(_ row: NSManagedObject) -> String { row.value(forKey: "rowID") as? String ?? row.objectID.uriRepresentation().absoluteString }

    private func documentRows(_ id: UUID) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedStoreModel.documentEntity)
        request.predicate = NSPredicate(format: "key == %@", documentKey(id))
        return try context.fetch(request).sorted { rowIdentity($0) < rowIdentity($1) }
    }

    /// Without uniqueness constraints, devices may hold duplicate rows for one logical
    /// document. Any tombstone wins; otherwise the lowest row UUID is the stable winner.
    private func activeDocumentRows(_ predicate: NSPredicate?) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedStoreModel.documentEntity)
        request.predicate = predicate
        let groups = Dictionary(grouping: try context.fetch(request)) { $0.value(forKey: "key") as? String ?? "" }
        return groups.compactMap { key, rows in
            guard !key.isEmpty, !rows.contains(where: { $0.value(forKey: "removed") as? Bool == true }) else { return nil }
            return rows.min { rowIdentity($0) < rowIdentity($1) }
        }
    }

    private func activeDocumentRow(_ id: UUID) throws -> NSManagedObject? {
        try activeDocumentRows(NSPredicate(format: "key == %@", documentKey(id))).first
    }

    private func contentRows(documentID: UUID) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: ManagedStoreModel.documentContentEntity)
        request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
        return try context.fetch(request).sorted { rowIdentity($0) < rowIdentity($1) }
    }

    /// "documentID|checksum" pairs present locally, read without faulting any bytes.
    private func availableContent(documentID: UUID? = nil) throws -> Set<String> {
        let request = NSFetchRequest<NSDictionary>(entityName: ManagedStoreModel.documentContentEntity)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["documentID", "checksum"]
        if let documentID { request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString) }
        return Set(try context.fetch(request).compactMap { entry in
            guard let id = entry["documentID"] as? String, let checksum = entry["checksum"] as? String else { return nil }
            return id + "|" + checksum
        })
    }

    private func insertContent(_ staged: StagedContent, documentID: UUID, metadataRow: NSManagedObject) {
        let content = insertRow(ManagedStoreModel.documentContentEntity, key: "documentContent:\(documentID.uuidString):\(staged.file.checksum)")
        content.setValue(documentID.uuidString, forKey: "documentID")
        content.setValue(staged.file.checksum, forKey: "checksum"); content.setValue(Int64(staged.file.byteCount), forKey: "byteCount")
        // Original bytes (or their ciphertext), unmodified: no resizing, recompression, or stripping.
        content.setValue(staged.bytes, forKey: "bytes")
        content.setValue(staged.encryption, forKey: "encryption"); content.setValue(staged.key, forKey: "contentKey")
        let file = staged.file
        metadataRow.setValue(file.filename, forKey: "filename"); metadataRow.setValue(file.contentType.rawValue, forKey: "contentType")
        metadataRow.setValue(Int64(file.byteCount), forKey: "byteCount"); metadataRow.setValue(file.checksum, forKey: "checksum")
    }

    private func apply(_ metadata: DocumentMetadata, to row: NSManagedObject) {
        row.setValue(metadata.title, forKey: "title"); row.setValue(metadata.category.rawValue, forKey: "category")
        row.setValue(metadata.notes, forKey: "notes")
        row.setValue(metadata.issuedOn?.timeIntervalSinceReferenceDate, forKey: "issuedOn")
        row.setValue(metadata.expiresOn?.timeIntervalSinceReferenceDate, forKey: "expiresOn")
        row.setValue(metadata.protection.rawValue, forKey: "protection")
    }

    /// Rows from a newer app version (unknown owner kind or content type) are skipped, not altered.
    private func makeDocument(_ row: NSManagedObject, available: Set<String>) -> ManagedDocument? {
        guard let idText = row.value(forKey: "id") as? String, let id = UUID(uuidString: idText),
              let kind = (row.value(forKey: "ownerKind") as? String).flatMap(DocumentOwner.Kind.init(rawValue:)),
              let ownerID = (row.value(forKey: "ownerID") as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        func date(_ key: String) -> Date? { (row.value(forKey: key) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } }
        // An unrecognized value from a newer version is treated as the stronger protection.
        let protection = (row.value(forKey: "protection") as? String).map { DocumentProtection(rawValue: $0) ?? .endToEnd } ?? .standard
        let metadata = DocumentMetadata(title: row.value(forKey: "title") as? String ?? "",
                                        category: DocumentCategory(rawValue: row.value(forKey: "category") as? String ?? DocumentCategory.other.rawValue),
                                        notes: row.value(forKey: "notes") as? String ?? "", issuedOn: date("issuedOn"), expiresOn: date("expiresOn"),
                                        protection: protection)
        var file: DocumentFile?
        if let checksum = row.value(forKey: "checksum") as? String {
            guard let type = (row.value(forKey: "contentType") as? String).flatMap(DocumentContentType.init(rawValue:)),
                  let count = row.value(forKey: "byteCount") as? NSNumber else { return nil }
            file = DocumentFile(filename: row.value(forKey: "filename") as? String ?? "Document.\(type.fileExtension)",
                                contentType: type, byteCount: count.intValue, checksum: checksum)
        }
        let link = (row.value(forKey: "linkURL") as? String).flatMap(URL.init(string:))
        guard link != nil || file != nil else { return nil }
        return ManagedDocument(id: id, owner: DocumentOwner(kind: kind, id: ownerID), metadata: metadata, link: link, file: file,
                               createdAt: date("createdAt") ?? .distantPast, updatedAt: date("updatedAt") ?? .distantPast,
                               isContentAvailable: file.map { available.contains(idText + "|" + $0.checksum) } ?? false)
    }
}

private extension Optional where Wrapped == ManagedDocument {
    func unwrapped() throws -> ManagedDocument {
        guard let self else { throw DocumentError.documentNotFound }
        return self
    }
}
#endif
