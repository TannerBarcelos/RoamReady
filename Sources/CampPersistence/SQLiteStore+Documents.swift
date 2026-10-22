#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CampCore

/// Core Data document vault. Metadata (`RR_document`) and original bytes
/// (`RR_documentContent.bytes`, external storage allowed) mirror through the same
/// NSPersistentCloudKitContainer as the rest of the library. No custom transfer queue exists.
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
        var link: URL?, upload: (file: DocumentFile, bytes: Data)?
        switch draft.source {
        case .link(let url): link = try DocumentPolicy.validatedLink(url)
        case .file(let bytes, let filename): upload = (try DocumentPolicy.inspect(bytes, filename: filename), bytes)
        }
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
                if let upload { try storeContent(upload.bytes, file: upload.file, documentID: draft.id, metadataRow: row) }
                try context.save()
                return try makeDocument(row, available: availableContent(documentID: draft.id)).unwrapped()
            } catch { context.rollback(); throw error }
        }
    }

    @discardableResult
    public func updateDocument(id: UUID, metadata: DocumentMetadata) async throws -> ManagedDocument {
        let metadata = try DocumentPolicy.validated(metadata)
        return try await context.perform { [self] in
            do {
                guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
                apply(metadata, to: row)
                row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                if context.hasChanges { try context.save() }
                return try makeDocument(row, available: availableContent(documentID: id)).unwrapped()
            } catch { context.rollback(); throw error }
        }
    }

    @discardableResult
    public func attachContent(toDocument id: UUID, bytes: Data, filename: String) async throws -> ManagedDocument {
        let file = try DocumentPolicy.inspect(bytes, filename: filename)
        return try await context.perform { [self] in
            do {
                guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
                guard row.value(forKey: "linkURL") as? String != nil else { throw DocumentError.notALink }
                // Re-importing a link deliberately replaces its previous imported snapshot.
                for old in try contentRows(documentID: id) where old.value(forKey: "checksum") as? String != file.checksum { context.delete(old) }
                try storeContent(bytes, file: file, documentID: id, metadataRow: row)
                row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                try context.save()
                return try makeDocument(row, available: availableContent(documentID: id)).unwrapped()
            } catch { context.rollback(); throw error }
        }
    }

    public func contents(ofDocument id: UUID) async throws -> DocumentContents {
        try await context.perform { [self] in
            context.refreshAllObjects()
            guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
            guard let file = makeDocument(row, available: [])?.file else { throw DocumentError.linkOnly }
            var sawCandidate = false
            for content in try contentRows(documentID: id) where content.value(forKey: "checksum") as? String == file.checksum {
                guard let bytes = content.value(forKey: "bytes") as? Data else { continue }
                sawCandidate = true
                // Copy before refaulting so the caller owns the bytes.
                let copy = Data(bytes)
                context.refresh(content, mergeChanges: false)
                if copy.count == file.byteCount, DocumentDigest.sha256(copy) == file.checksum { return DocumentContents(file: file, bytes: copy) }
            }
            throw sawCandidate ? DocumentError.contentIntegrity : DocumentError.contentNotDownloaded
        }
    }

    public func deleteDocument(id: UUID) async throws {
        try await context.perform { [self] in
            do {
                let rows = try documentRows(id)
                guard rows.contains(where: { $0.value(forKey: "removed") as? Bool != true }) else { throw DocumentError.documentNotFound }
                // Keep an identity-only tombstone so a stale device cannot resurrect it, and drop
                // personal metadata. Bytes are removed so storage is actually released.
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

    private func storeContent(_ bytes: Data, file: DocumentFile, documentID: UUID, metadataRow: NSManagedObject) throws {
        if try !contentRows(documentID: documentID).contains(where: { $0.value(forKey: "checksum") as? String == file.checksum }) {
            let content = insertRow(ManagedStoreModel.documentContentEntity, key: "documentContent:\(documentID.uuidString):\(file.checksum)")
            content.setValue(documentID.uuidString, forKey: "documentID")
            content.setValue(file.checksum, forKey: "checksum"); content.setValue(Int64(file.byteCount), forKey: "byteCount")
            // The caller's bytes, unmodified. No resizing, recompression, or metadata stripping.
            content.setValue(bytes, forKey: "bytes")
        }
        metadataRow.setValue(file.filename, forKey: "filename"); metadataRow.setValue(file.contentType.rawValue, forKey: "contentType")
        metadataRow.setValue(Int64(file.byteCount), forKey: "byteCount"); metadataRow.setValue(file.checksum, forKey: "checksum")
    }

    private func apply(_ metadata: DocumentMetadata, to row: NSManagedObject) {
        row.setValue(metadata.title, forKey: "title"); row.setValue(metadata.category.rawValue, forKey: "category")
        row.setValue(metadata.notes, forKey: "notes")
        row.setValue(metadata.issuedOn?.timeIntervalSinceReferenceDate, forKey: "issuedOn")
        row.setValue(metadata.expiresOn?.timeIntervalSinceReferenceDate, forKey: "expiresOn")
    }

    /// Rows from a newer app version (unknown owner kind or content type) are skipped, not altered.
    private func makeDocument(_ row: NSManagedObject, available: Set<String>) -> ManagedDocument? {
        guard let idText = row.value(forKey: "id") as? String, let id = UUID(uuidString: idText),
              let kind = (row.value(forKey: "ownerKind") as? String).flatMap(DocumentOwner.Kind.init(rawValue:)),
              let ownerID = (row.value(forKey: "ownerID") as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        func date(_ key: String) -> Date? { (row.value(forKey: key) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } }
        let metadata = DocumentMetadata(title: row.value(forKey: "title") as? String ?? "",
                                        category: DocumentCategory(rawValue: row.value(forKey: "category") as? String ?? DocumentCategory.other.rawValue),
                                        notes: row.value(forKey: "notes") as? String ?? "", issuedOn: date("issuedOn"), expiresOn: date("expiresOn"))
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
