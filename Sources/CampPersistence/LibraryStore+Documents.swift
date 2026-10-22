#if canImport(CoreData)
import Foundation
@preconcurrency import CoreData
import CloudKit
import CryptoKit
import CampCore
import DocumentVault

/// Core Data document vault. Metadata (`RR_document`) and file chunks (`RR_documentContent`, one
/// row per 1 MiB with external binary storage allowed) mirror through the same
/// NSPersistentCloudKitContainer as the rest of the library. No custom transfer queue exists.
///
/// Memory stays bounded by a small batch of chunks regardless of file size: uploads are read,
/// hashed, and (when protected) encrypted chunk by chunk, saved in batches, and refaulted; reads
/// fetch, verify, and release one chunk at a time. A file becomes visible only when every chunk of
/// one version is present, so batched writes and partial CloudKit imports are never exposed.
extension LibraryStore: DocumentRepository {
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
        let upload = try draft.source.byteSource.map { ($0.source, try DocumentPolicy.inspect($0.source, filename: $0.filename)) }
        // Tombstoned identifiers are never reused. Checked first so no chunks are written in vain.
        guard try await context.perform({ [self] in try documentRows(draft.id).isEmpty }) else { throw DocumentError.duplicateDocument }
        var version: StoredVersion?
        if let upload { version = try await writeVersion(upload.0, file: upload.1, documentID: draft.id, protection: metadata.protection) }
        let written = version
        do {
            return try await context.perform { [self] in
                do {
                    guard try documentRows(draft.id).isEmpty else { throw DocumentError.duplicateDocument }
                    let row = insertRow(LibraryModel.documentEntity, key: documentKey(draft.id))
                    row.setValue(draft.id.uuidString, forKey: "id")
                    row.setValue(draft.owner.kind.rawValue, forKey: "ownerKind"); row.setValue(draft.owner.id.uuidString, forKey: "ownerID")
                    row.setValue(draft.createdAt.timeIntervalSinceReferenceDate, forKey: "createdAt")
                    row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                    apply(metadata, to: row)
                    row.setValue(link?.absoluteString, forKey: "linkURL")
                    if let written { setFile(written.file, on: row); try putMeta(written.pendingMarker, nil) }
                    try context.save()
                    return try makeDocument(row, available: availableContent(documentID: draft.id)).unwrapped()
                } catch { context.rollback(); throw error }
            }
        } catch {
            if let written { await discardVersion(written) }
            throw error
        }
    }

    @discardableResult
    public func updateDocument(id: UUID, metadata: DocumentMetadata) async throws -> ManagedDocument {
        var validated = try DocumentPolicy.validated(metadata)
        guard let current = try await document(id: id) else { throw DocumentError.documentNotFound }
        // Protection is only ever raised. Raising it re-encrypts the stored file as a new version.
        validated.protection = max(validated.protection, current.metadata.protection)
        var version: StoredVersion?
        if validated.protection > current.metadata.protection, let file = current.file {
            guard current.isContentAvailable else { throw DocumentError.protectionNeedsContent }
            let plaintext = stagingURL()
            defer { try? FileManager.default.removeItem(at: plaintext) }
            try await exportContents(ofDocument: id, to: plaintext)
            version = try await writeVersion(.file(plaintext), file: file, documentID: id, protection: validated.protection)
        }
        let replacement = version, finalMetadata = validated
        do {
            return try await context.perform { [self] in
                do {
                    guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
                    if let replacement {
                        // The file must not have changed since it was read for re-encryption.
                        guard row.value(forKey: "checksum") as? String == replacement.file.checksum else { throw DocumentError.contentIntegrity }
                        for old in try contentRows(documentID: id) where old.value(forKey: "versionID") as? String != replacement.versionID { context.delete(old) }
                        try putMeta(replacement.pendingMarker, nil)
                    }
                    apply(finalMetadata, to: row)
                    row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                    if context.hasChanges { try context.save() }
                    return try makeDocument(row, available: availableContent(documentID: id)).unwrapped()
                } catch { context.rollback(); throw error }
            }
        } catch {
            if let replacement { await discardVersion(replacement) }
            throw error
        }
    }

    @discardableResult
    public func attachContent(toDocument id: UUID, source: DocumentByteSource, filename: String) async throws -> ManagedDocument {
        let file = try DocumentPolicy.inspect(source, filename: filename)
        guard let current = try await document(id: id) else { throw DocumentError.documentNotFound }
        guard current.link != nil else { throw DocumentError.notALink }
        let version = try await writeVersion(source, file: file, documentID: id, protection: current.metadata.protection)
        do {
            return try await context.perform { [self] in
                do {
                    guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
                    // Re-importing a link deliberately replaces its previous imported copy.
                    for old in try contentRows(documentID: id) where old.value(forKey: "versionID") as? String != version.versionID { context.delete(old) }
                    setFile(file, on: row); try putMeta(version.pendingMarker, nil)
                    row.setValue(Date().timeIntervalSinceReferenceDate, forKey: "updatedAt")
                    try context.save()
                    return try makeDocument(row, available: availableContent(documentID: id)).unwrapped()
                } catch { context.rollback(); throw error }
            }
        } catch {
            await discardVersion(version)
            throw error
        }
    }

    public func contents(ofDocument id: UUID) async throws -> DocumentContents {
        let (file, versions) = try await completeVersions(id)
        for version in versions {
            var bytes = Data()
            do { try await read(version, file: file, documentID: id) { bytes.append($0) }; return DocumentContents(file: file, bytes: bytes) }
            catch DocumentError.contentIntegrity { continue }
        }
        throw versions.isEmpty ? DocumentError.contentNotDownloaded : DocumentError.contentIntegrity
    }

    @discardableResult
    public func exportContents(ofDocument id: UUID, to url: URL) async throws -> DocumentFile {
        let (file, versions) = try await completeVersions(id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for version in versions {
            // Write beside the destination; only a fully verified file is moved into place.
            let partial = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
            do {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: partial)
                do { try await read(version, file: file, documentID: id) { try handle.write(contentsOf: $0) }; try handle.close() }
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
        throw versions.isEmpty ? DocumentError.contentNotDownloaded : DocumentError.contentIntegrity
    }

    public func deleteDocument(id: UUID) async throws {
        try await context.perform { [self] in
            do {
                let rows = try documentRows(id)
                guard rows.contains(where: { $0.value(forKey: "removed") as? Bool != true }) else { throw DocumentError.documentNotFound }
                // Keep an identity-only tombstone so a stale device cannot resurrect it, and drop
                // personal metadata. Every chunk row (bytes and keys) is removed to release storage.
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

    /// Whether this document and every chunk of its current file have iCloud records. This reflects
    /// Core Data's mirroring metadata on this device; a metadata edit made after the upload is not
    /// distinguished from the uploaded version.
    public func cloudStatus(ofDocument id: UUID) async throws -> DocumentCloudStatus {
        guard cloudEnabled else { return .localOnly }
        let objectIDs = try await context.perform { [self] () -> [NSManagedObjectID] in
            guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
            var ids = [row.objectID]
            if let checksum = row.value(forKey: "checksum") as? String {
                let chunks = try contentRows(documentID: id).filter { $0.value(forKey: "checksum") as? String == checksum }
                let versions = Dictionary(grouping: chunks) { $0.value(forKey: "versionID") as? String ?? "" }
                // A file not yet downloaded here came from iCloud; the document record decides.
                guard let complete = versions.values.first(where: { isComplete($0) }) else { return ids }
                ids += complete.map(\.objectID)
            }
            return ids
        }
        guard !objectIDs.isEmpty else { return .waitingToUpload }
        return container.records(for: objectIDs).count == objectIDs.count ? .inICloud : .waitingToUpload
    }

    // MARK: Chunked versions

    /// A file version whose chunks are saved but not yet referenced by its document.
    struct StoredVersion: Sendable {
        let file: DocumentFile
        let versionID: String
        let documentID: UUID
        var pendingMarker: String { "pendingDocumentVersion:\(documentID.uuidString):\(versionID)" }
    }

    /// Chunks per save. Bounds memory to a few MiB however Core Data buffers values internally.
    static let chunksPerSave = 4
    static let stagingDirectoryName = "DocumentStaging"
    private func stagingURL() -> URL {
        directory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true).appendingPathComponent(UUID().uuidString)
    }

    /// Reads `source` chunk by chunk, encrypting when protected, and saves the chunks in batches.
    /// A device-only marker lets the next launch remove the chunks if the app stops before the
    /// document references them. The source must be exactly the bytes described by `file`.
    private func writeVersion(_ source: DocumentByteSource, file: DocumentFile, documentID: UUID, protection: DocumentProtection) async throws -> StoredVersion {
        let version = StoredVersion(file: file, versionID: UUID().uuidString, documentID: documentID)
        let key = protection == .endToEnd ? DocumentCipher.newKey() : nil
        let keyData = key.map { $0.withUnsafeBytes { Data($0) } }
        let count = DocumentChunkReader.chunkCount(byteCount: file.byteCount)
        try await context.perform { [self] in
            do { try putMeta(version.pendingMarker, Data(file.checksum.utf8)); try context.save() } catch { context.rollback(); throw error }
        }
        do {
            let reader = try DocumentChunkReader(source)
            var hasher = DocumentHasher(), index = 0, total = 0
            while true {
                var batch: [(index: Int, bytes: Data, checksum: String)] = []
                while batch.count < Self.chunksPerSave, let plaintext = try reader.next() {
                    guard index < count else { throw DocumentError.contentIntegrity }
                    hasher.update(plaintext); total += plaintext.count
                    let stored = try key.map { try DocumentCipher.seal(plaintext, key: $0, documentID: documentID, index: index, final: index == count - 1) } ?? plaintext
                    batch.append((index, stored, DocumentDigest.sha256(plaintext))); index += 1
                }
                guard !batch.isEmpty else { break }
                let pending = batch
                try await context.perform { [self] in
                    do {
                        let rows = pending.map { chunk in
                            let row = insertRow(LibraryModel.documentContentEntity, key: "documentContent:\(documentID.uuidString):\(version.versionID):\(chunk.index)")
                            row.setValue(documentID.uuidString, forKey: "documentID"); row.setValue(version.versionID, forKey: "versionID")
                            row.setValue(file.checksum, forKey: "checksum"); row.setValue(Int64(file.byteCount), forKey: "byteCount")
                            row.setValue(Int64(chunk.index), forKey: "chunkIndex"); row.setValue(Int64(count), forKey: "chunkCount")
                            row.setValue(chunk.checksum, forKey: "chunkChecksum")
                            // Original bytes (or their ciphertext), unmodified: no resizing, recompression, or stripping.
                            row.setValue(chunk.bytes, forKey: "bytes")
                            row.setValue(keyData == nil ? nil : DocumentCipher.scheme, forKey: "encryption"); row.setValue(keyData, forKey: "contentKey")
                            return row
                        }
                        try context.save()
                        rows.forEach { context.refresh($0, mergeChanges: false) }
                    } catch { context.rollback(); throw error }
                }
            }
            // A file that changed while being read is not the file that was inspected.
            guard index == count, total == file.byteCount, hasher.finalize() == file.checksum else { throw DocumentError.contentIntegrity }
            return version
        } catch {
            await discardVersion(version)
            throw error
        }
    }

    /// Removes an unreferenced version's chunks and its marker. Best effort; also run at launch.
    private func discardVersion(_ version: StoredVersion) async {
        try? await context.perform { [self] in
            do {
                for row in try contentRows(documentID: version.documentID) where row.value(forKey: "versionID") as? String == version.versionID {
                    context.delete(row)
                }
                try putMeta(version.pendingMarker, nil)
                try context.save()
            } catch { context.rollback(); throw error }
        }
    }

    /// Chunks left by an import interrupted on this device are never referenced; remove them.
    /// Only this device's own markers are considered, so chunks still arriving from other
    /// devices through CloudKit are never touched.
    func cleanUpInterruptedDocumentWrites() async throws {
        let markers = try await context.perform { [self] () -> [String] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.metadataEntity)
            request.predicate = NSPredicate(format: "key BEGINSWITH %@ AND value != nil", "pendingDocumentVersion:")
            return try context.fetch(request).compactMap { $0.value(forKey: "key") as? String }
        }
        for marker in markers {
            let parts = marker.split(separator: ":")
            guard parts.count == 3, let documentID = UUID(uuidString: String(parts[1])) else { continue }
            await discardVersion(StoredVersion(file: DocumentFile(filename: "", contentType: .pdf, byteCount: 0, checksum: ""),
                                               versionID: String(parts[2]), documentID: documentID))
        }
    }

    /// Object IDs are immutable identifiers that are safe to pass between contexts.
    struct ChunkRef: @unchecked Sendable {
        let objectID: NSManagedObjectID
        let checksum: String
    }
    struct CompleteVersion: @unchecked Sendable {
        let chunks: [ChunkRef]
        let encryption: String?
        let key: Data?
    }

    /// Complete versions of the current file, in a deterministic order. No bytes are loaded.
    private func completeVersions(_ id: UUID) async throws -> (DocumentFile, [CompleteVersion]) {
        try await context.perform { [self] in
            context.refreshAllObjects()
            guard let row = try activeDocumentRow(id) else { throw DocumentError.documentNotFound }
            guard let file = makeDocument(row, available: [])?.file else { throw DocumentError.linkOnly }
            let rows = try contentRows(documentID: id).filter { $0.value(forKey: "checksum") as? String == file.checksum }
            let versions = Dictionary(grouping: rows) { $0.value(forKey: "versionID") as? String ?? "" }
            let complete = versions.keys.sorted().compactMap { versionID -> CompleteVersion? in
                guard let chunks = versions[versionID], isComplete(chunks) else { return nil }
                let ordered = chunks.sorted { ($0.value(forKey: "chunkIndex") as? Int64 ?? 0) < ($1.value(forKey: "chunkIndex") as? Int64 ?? 0) }
                let refs = ordered.compactMap { chunk in (chunk.value(forKey: "chunkChecksum") as? String).map { ChunkRef(objectID: chunk.objectID, checksum: $0) } }
                guard refs.count == ordered.count else { return nil }
                defer { chunks.forEach { context.refresh($0, mergeChanges: false) } }
                return CompleteVersion(chunks: refs, encryption: ordered[0].value(forKey: "encryption") as? String,
                                       key: ordered[0].value(forKey: "contentKey") as? Data)
            }
            return (file, complete)
        }
    }

    /// Fetches, verifies, and releases one chunk at a time, passing plaintext to `sink` in order.
    /// Throws `contentIntegrity` at the first chunk that fails, so output is provisional until
    /// this returns.
    private func read(_ version: CompleteVersion, file: DocumentFile, documentID: UUID, into sink: (Data) throws -> Void) async throws {
        let key: SymmetricKey?
        switch version.encryption {
        case nil: key = nil
        case DocumentCipher.scheme?:
            guard let data = version.key, data.count == 32 else { throw DocumentError.contentIntegrity }
            key = SymmetricKey(data: data)
        default: throw DocumentError.contentIntegrity
        }
        var hasher = DocumentHasher(), total = 0
        for (index, chunk) in version.chunks.enumerated() {
            let stored = try await context.perform { [self] () -> Data? in
                let row = try context.existingObject(with: chunk.objectID)
                defer { context.refresh(row, mergeChanges: false) }
                return row.value(forKey: "bytes") as? Data
            }
            guard let stored else { throw DocumentError.contentNotDownloaded }
            let plaintext = try key.map { try DocumentCipher.open(stored, key: $0, documentID: documentID, index: index, final: index == version.chunks.count - 1) } ?? stored
            guard DocumentDigest.sha256(plaintext) == chunk.checksum else { throw DocumentError.contentIntegrity }
            hasher.update(plaintext); total += plaintext.count
            try sink(plaintext)
        }
        guard total == file.byteCount, hasher.finalize() == file.checksum else { throw DocumentError.contentIntegrity }
    }

    // MARK: Rows (call inside `context.perform`)

    /// All chunks 0..<chunkCount present exactly once, with a consistent count.
    private func isComplete(_ chunks: [NSManagedObject]) -> Bool {
        let counts = Set(chunks.compactMap { $0.value(forKey: "chunkCount") as? Int64 })
        guard counts.count == 1, let count = counts.first, count > 0 else { return false }
        let indices = chunks.compactMap { $0.value(forKey: "chunkIndex") as? Int64 }
        return indices.count == Int(count) && Set(indices) == Set(0..<count)
    }

    private func documentKey(_ id: UUID) -> String { "document:\(id.uuidString)" }

    private func insertRow(_ entity: String, key: String) -> NSManagedObject {
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        row.setValue(key, forKey: "key"); row.setValue(UUID().uuidString, forKey: "rowID")
        return row
    }

    private func rowIdentity(_ row: NSManagedObject) -> String { row.value(forKey: "rowID") as? String ?? row.objectID.uriRepresentation().absoluteString }

    private func documentRows(_ id: UUID) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentEntity)
        request.predicate = NSPredicate(format: "key == %@", documentKey(id))
        return try context.fetch(request).sorted { rowIdentity($0) < rowIdentity($1) }
    }

    /// Without uniqueness constraints, devices may hold duplicate rows for one logical
    /// document. Any tombstone wins; otherwise the lowest row UUID is the stable winner.
    private func activeDocumentRows(_ predicate: NSPredicate?) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentEntity)
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

    /// Chunk rows for a document. Bytes are faults until read.
    private func contentRows(documentID: UUID) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentContentEntity)
        request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
        request.returnsObjectsAsFaults = true
        return try context.fetch(request).sorted { rowIdentity($0) < rowIdentity($1) }
    }

    /// "documentID|checksum" for every complete version present locally, read without faulting bytes.
    private func availableContent(documentID: UUID? = nil) throws -> Set<String> {
        let request = NSFetchRequest<NSDictionary>(entityName: LibraryModel.documentContentEntity)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["documentID", "checksum", "versionID", "chunkIndex", "chunkCount"]
        if let documentID { request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString) }
        var versions: [String: (key: String, count: Int64, indices: Set<Int64>)] = [:]
        for entry in try context.fetch(request) {
            guard let id = entry["documentID"] as? String, let checksum = entry["checksum"] as? String, let versionID = entry["versionID"] as? String,
                  let index = entry["chunkIndex"] as? Int64, let count = entry["chunkCount"] as? Int64 else { continue }
            var version = versions[versionID] ?? (id + "|" + checksum, count, [])
            guard version.count == count else { version.count = -1; versions[versionID] = version; continue }
            version.indices.insert(index); versions[versionID] = version
        }
        return Set(versions.values.filter { $0.count > 0 && $0.indices == Set(0..<$0.count) }.map(\.key))
    }

    private func setFile(_ file: DocumentFile, on row: NSManagedObject) {
        row.setValue(file.filename, forKey: "filename"); row.setValue(file.contentType.rawValue, forKey: "contentType")
        row.setValue(Int64(file.byteCount), forKey: "byteCount"); row.setValue(file.checksum, forKey: "checksum")
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
