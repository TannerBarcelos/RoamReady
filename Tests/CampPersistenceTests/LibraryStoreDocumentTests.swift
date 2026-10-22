#if canImport(CoreData)
import Foundation
import CoreData
import XCTest
import CampCore
import DocumentVault
@testable import CampPersistence

final class LibraryStoreDocumentTests: XCTestCase, @unchecked Sendable {
    /// Bytes past a valid PDF signature are arbitrary and must survive unchanged.
    private static func pdf(size: Int = 64) -> Data {
        var data = Data("%PDF-1.7\n".utf8)
        data.append(contentsOf: (0..<max(0, size - data.count)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        return data
    }
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0xDE, 0xAD])
    private let rig = DocumentOwner.rig(UUID()), trip = DocumentOwner.trip(UUID())

    private func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
    private func library() throws -> LibrarySnapshot {
        let rig = Rig(make: "Test", model: "Trailer")
        var state = AppState(profile: CamperProfile())
        try state.addRig(rig)
        _ = try state.createTrip(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_750_000_000),
                                 departure: Date(timeIntervalSince1970: 1_750_086_400), rigID: rig.id)
        return LibrarySnapshot(state: state, saved: ["ridb-232447": SavedCampground(campgroundID: "ridb-232447", wantToGo: true)])
    }
    private func expectError<T>(_ expected: DocumentError, _ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? DocumentError, expected, file: file, line: line) }
    }

    // MARK: Schema

    func testRecordEntitiesStoreExactlyTheirDeclaredFields() {
        let model = LibraryModel.make()
        XCTAssertEqual(model.versionIdentifiers, [LibraryModel.version])
        for kind in RecordKind.allCases {
            let entity = model.entitiesByName[LibraryModel.entityName(kind)]!
            var expected = Set(LibraryModel.fields(kind).keys).union(["key", "rowID", "removed"])
            if kind == .asset { expected.insert("bytes") }
            XCTAssertEqual(Set(entity.attributesByName.keys), expected, kind.rawValue)
            for (name, type) in LibraryModel.fields(kind) { XCTAssertEqual(entity.attributesByName[name]?.attributeType, type, name) }
            XCTAssertTrue(entity.attributesByName.values.allSatisfy { !$0.allowsCloudEncryption }, kind.rawValue)
        }
        XCTAssertEqual(model.entities(forConfigurationName: LibraryModel.device)?.map(\.name), [LibraryModel.metadataEntity])
    }

    func testDocumentEntitiesAreCloudKitCompatibleAndMirrored() throws {
        let model = LibraryModel.make()
        let library = Set(model.entities(forConfigurationName: "Library")!.map(\.name!))
        XCTAssertTrue(library.isSuperset(of: [LibraryModel.documentEntity, LibraryModel.documentContentEntity]))
        for name in [LibraryModel.documentEntity, LibraryModel.documentContentEntity] {
            let entity = try XCTUnwrap(model.entitiesByName[name])
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            XCTAssertTrue(entity.relationshipsByName.isEmpty)
            XCTAssertTrue(entity.attributesByName.values.allSatisfy { $0.isOptional || $0.defaultValue != nil })
        }
        XCTAssertEqual(model.entitiesByName[LibraryModel.documentContentEntity]?.attributesByName["bytes"]?.allowsExternalBinaryDataStorage, true)
        XCTAssertNil(model.entitiesByName[LibraryModel.documentEntity]?.attributesByName["bytes"], "Listings must not fault document bytes")
        let metadata = try XCTUnwrap(model.entitiesByName[LibraryModel.documentEntity])
        let encrypted = Set(metadata.attributesByName.values.filter(\.allowsCloudEncryption).map(\.name))
        XCTAssertEqual(encrypted, ["title", "notes", "linkURL", "filename"])
        let content = try XCTUnwrap(model.entitiesByName[LibraryModel.documentContentEntity])
        XCTAssertEqual(Set(content.attributesByName.values.filter(\.allowsCloudEncryption).map(\.name)), ["contentKey"])
        XCTAssertEqual(content.attributesByName["bytes"]?.allowsCloudEncryption, false, "Assets cannot use CloudKit field encryption")
    }

    // MARK: Persistence

    func testUploadedOriginalBytesSurviveRelaunchWithoutNetwork() async throws {
        let d = try directory()
        let manual = Self.pdf(size: 3_000_000), photo = Self.png
        let issued = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let metadata = DocumentMetadata(title: "Owner’s manual", category: .manual, notes: "Chassis section p. 40", issuedOn: issued, expiresOn: issued.addingTimeInterval(86_400 * 365))
        let store = try await LibraryStore.open(directory: d)
        let added = try await store.addDocument(DocumentDraft(owner: rig, metadata: metadata, source: .file(manual, filename: "Manual.pdf")))
        let card = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Insurance card", category: .insurance), source: .file(photo, filename: "card.png")))
        XCTAssertEqual(added.availability, .offline)
        XCTAssertEqual(added.file, DocumentFile(filename: "Manual.pdf", contentType: .pdf, byteCount: manual.count, checksum: DocumentDigest.sha256(manual)))
        try await store.close()

        let reopened = try await LibraryStore.open(directory: d)
        let listed = try await reopened.documents(ownedBy: rig)
        XCTAssertEqual(Set(listed.map(\.id)), [added.id, card.id])
        let restored = try XCTUnwrap(listed.first { $0.id == added.id })
        XCTAssertEqual(restored.metadata, metadata); XCTAssertEqual(restored.file, added.file)
        XCTAssertEqual(restored.createdAt.timeIntervalSinceReferenceDate, added.createdAt.timeIntervalSinceReferenceDate, accuracy: 0.001)
        XCTAssertEqual(restored.availability, .offline)
        let bytes = try await reopened.contents(ofDocument: added.id).bytes
        XCTAssertEqual(bytes, manual)
        let image = try await reopened.contents(ofDocument: card.id)
        XCTAssertEqual(image.bytes, photo); XCTAssertEqual(image.file.contentType, .png)
        // Library snapshots are unaffected by documents.
        let snapshot = try await reopened.snapshot(); XCTAssertEqual(snapshot, LibrarySnapshot())
        try await reopened.close()
    }

    func testMetadataEditsPersistAndOwnersStaySeparate() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d)
        let rigDoc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Registration", category: .registration), source: .file(Self.pdf(), filename: "reg.pdf")))
        let tripDoc = try await store.addDocument(DocumentDraft(owner: trip, metadata: DocumentMetadata(title: "Site map", category: .reservation), source: .link(URL(string: "https://example.com/map")!)))
        let edited = DocumentMetadata(title: "Registration 2027", category: .registration, notes: "Renew online", expiresOn: Date(timeIntervalSinceReferenceDate: 900_000_000), protection: .endToEnd)
        _ = try await store.updateDocument(id: rigDoc.id, metadata: edited)
        await expectError(.missingTitle) { try await store.updateDocument(id: rigDoc.id, metadata: DocumentMetadata(title: " ")) }
        try await store.close()
        let reopened = try await LibraryStore.open(directory: d)
        let rigDocs = try await reopened.documents(ownedBy: rig), tripDocs = try await reopened.documents(ownedBy: trip)
        XCTAssertEqual(rigDocs.map(\.id), [rigDoc.id]); XCTAssertEqual(rigDocs.first?.metadata, edited)
        XCTAssertEqual(tripDocs.map(\.id), [tripDoc.id])
        let all = try await reopened.documents(ownedBy: nil); XCTAssertEqual(all.count, 2)
        try await reopened.close()
    }

    func testLinksStayOnlineOnlyUntilContentsAreExplicitlyImported() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d)
        let url = URL(string: "https://example.com/confirmation?id=42")!
        let link = try await store.addDocument(DocumentDraft(owner: trip, metadata: DocumentMetadata(title: "Reservation", category: .reservation), source: .link(url)))
        XCTAssertEqual(link.availability, .onlineOnly); XCTAssertNil(link.file)
        await expectError(.linkOnly) { try await store.contents(ofDocument: link.id) }
        let pdf = Self.pdf(size: 4096)
        let imported = try await store.attachContent(toDocument: link.id, bytes: pdf, filename: "confirmation.pdf")
        XCTAssertEqual(imported.link, url); XCTAssertEqual(imported.availability, .offline)
        // Re-importing replaces the earlier snapshot rather than accumulating copies.
        _ = try await store.attachContent(toDocument: link.id, bytes: Self.png, filename: "confirmation.png")
        let snapshots = try await contentRowCount(store, documentID: link.id); XCTAssertEqual(snapshots, 1)
        try await store.close()
        let reopened = try await LibraryStore.open(directory: d)
        let offline = try await reopened.contents(ofDocument: link.id)
        XCTAssertEqual(offline.bytes, Self.png)
        let restored = try await reopened.document(id: link.id); XCTAssertEqual(restored?.link, url)
        try await reopened.close()
    }

    func testInvalidImportsAreRejectedWithoutWritingAnything() async throws {
        let store = try await LibraryStore.open(directory: directory())
        let meta = DocumentMetadata(title: "Manual")
        await expectError(.unsupportedFileType) { try await store.addDocument(DocumentDraft(owner: rig, metadata: meta, source: .file(Data("PK\u{3}\u{4}not a pdf".utf8), filename: "manual.pdf"))) }
        await expectError(.emptyFile) { try await store.addDocument(DocumentDraft(owner: rig, metadata: meta, source: .file(Data(), filename: "empty.pdf"))) }
        await expectError(.insecureLink) { try await store.addDocument(DocumentDraft(owner: rig, metadata: meta, source: .link(URL(string: "http://example.com/manual.pdf")!))) }
        await expectError(.invalidLink) { try await store.addDocument(DocumentDraft(owner: rig, metadata: meta, source: .link(URL(string: "file:///etc/hosts")!))) }
        await expectError(.missingTitle) { try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: ""), source: .file(Self.pdf(), filename: "a.pdf"))) }
        let file = try await store.addDocument(DocumentDraft(owner: rig, metadata: meta, source: .file(Self.pdf(), filename: "a.pdf")))
        await expectError(.notALink) { try await store.attachContent(toDocument: file.id, bytes: Self.png, filename: "b.png") }
        await expectError(.duplicateDocument) { try await store.addDocument(DocumentDraft(id: file.id, owner: rig, metadata: meta, source: .file(Self.png, filename: "c.png"))) }
        await expectError(.documentNotFound) { try await store.contents(ofDocument: UUID()) }
        let listed = try await store.documents(ownedBy: nil); XCTAssertEqual(listed.map(\.id), [file.id])
        let original = try await store.contents(ofDocument: file.id).bytes; XCTAssertEqual(original, Self.pdf())
        try await store.close()
    }

    func testMetadataWithoutDownloadedContentReportsMissingAndTamperingIsDetected() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d)
        let added = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Warranty"), source: .file(Self.pdf(), filename: "w.pdf")))
        // Simulate a mirrored metadata record whose content record has not arrived yet.
        try await mutateContent(store, documentID: added.id) { rows, context in rows.forEach(context.delete) }
        let pending = try await store.document(id: added.id); XCTAssertEqual(pending?.availability, .awaitingDownload)
        await expectError(.contentNotDownloaded) { try await store.contents(ofDocument: added.id) }

        let tampered = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Card"), source: .file(Self.png, filename: "c.png")))
        try await mutateContent(store, documentID: tampered.id) { rows, _ in
            var bytes = Self.png; bytes[bytes.count - 1] ^= 0xFF
            rows.forEach { $0.setValue(bytes, forKey: "bytes") }
        }
        await expectError(.contentIntegrity) { try await store.contents(ofDocument: tampered.id) }
        try await store.close()
        let reopened = try await LibraryStore.open(directory: d)
        await expectError(.contentNotDownloaded) { try await reopened.contents(ofDocument: added.id) }
        try await reopened.close()
    }

    func testDeliberateDeletionRemovesBytesAndLeavesIdentityOnlyTombstone() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d)
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Private policy", notes: "Policy #123"), source: .file(Self.pdf(size: 2_000_000), filename: "p.pdf")))
        let keep = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Keep"), source: .file(Self.png, filename: "k.png")))
        try await store.deleteDocument(id: doc.id)
        await expectError(.documentNotFound) { try await store.deleteDocument(id: doc.id) }
        let gone = try await store.document(id: doc.id); XCTAssertNil(gone)
        let remaining = try await contentRowCount(store, documentID: doc.id); XCTAssertEqual(remaining, 0)
        let tombstone = try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentEntity)
            request.predicate = NSPredicate(format: "id == %@", doc.id.uuidString)
            return try store.context.fetch(request).map { [$0.value(forKey: "removed") as? Bool == true, $0.value(forKey: "title") == nil, $0.value(forKey: "notes") == nil] }
        }
        XCTAssertEqual(tombstone, [[true, true, true]])
        await expectError(.duplicateDocument) { try await store.addDocument(DocumentDraft(id: doc.id, owner: rig, metadata: DocumentMetadata(title: "Again"), source: .file(Self.png, filename: "a.png"))) }
        try await store.close()
        let reopened = try await LibraryStore.open(directory: d)
        let listed = try await reopened.documents(ownedBy: rig); XCTAssertEqual(listed.map(\.id), [keep.id])
        try await reopened.close()
    }

    func testDuplicateLogicalDocumentRowsReconcileDeterministically() async throws {
        let store = try await LibraryStore.open(directory: directory())
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Original"), source: .link(URL(string: "https://example.com")!)))
        try await store.context.perform { [store] in
            let row = NSEntityDescription.insertNewObject(forEntityName: LibraryModel.documentEntity, into: store.context)
            for (key, value) in ["key": "document:\(doc.id.uuidString)", "rowID": "000-first", "id": doc.id.uuidString, "ownerKind": "rig",
                                 "ownerID": doc.owner.id.uuidString, "title": "Chosen duplicate", "category": "other", "linkURL": "https://example.com/dup"] {
                row.setValue(value, forKey: key)
            }
            row.setValue(1.0, forKey: "createdAt")
            try store.context.save()
        }
        let listed = try await store.documents(ownedBy: rig)
        XCTAssertEqual(listed.count, 1); XCTAssertEqual(listed.first?.metadata.title, "Chosen duplicate")
        try await store.close()
    }

    // MARK: Chunked storage, streaming, and end-to-end protection

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = try directory().appendingPathComponent("source.pdf")
        try data.write(to: url)
        return url
    }

    private struct StoredChunk: Sendable { let index: Int; let count: Int; let bytes: Data; let encryption: String?; let key: Data? }

    private func storedChunks(_ store: LibraryStore, documentID: UUID) async throws -> [StoredChunk] {
        try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentContentEntity)
            request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
            return try store.context.fetch(request).map {
                StoredChunk(index: Int($0.value(forKey: "chunkIndex") as? Int64 ?? -1), count: Int($0.value(forKey: "chunkCount") as? Int64 ?? -1),
                            bytes: $0.value(forKey: "bytes") as? Data ?? Data(), encryption: $0.value(forKey: "encryption") as? String,
                            key: $0.value(forKey: "contentKey") as? Data)
            }.sorted { $0.index < $1.index }
        }
    }

    private func mutateChunks(_ store: LibraryStore, documentID: UUID, _ change: @escaping @Sendable (NSManagedObject, Int, NSManagedObjectContext) -> Void) async throws {
        try await mutateContent(store, documentID: documentID) { rows, context in
            for row in rows { change(row, Int(row.value(forKey: "chunkIndex") as? Int64 ?? -1), context) }
        }
    }

    func testFilesAreStoredAsBoundedChunkRows() async throws {
        let store = try await LibraryStore.open(directory: directory())
        let size = 3 * DocumentCipher.chunkSize + 500, plaintext = Self.pdf(size: size)
        for category in [DocumentCategory.manual, .insurance] {
            let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Doc", category: category), source: .file(plaintext, filename: "d.pdf")))
            let chunks = try await storedChunks(store, documentID: doc.id)
            XCTAssertEqual(chunks.map(\.index), [0, 1, 2, 3]); XCTAssertTrue(chunks.allSatisfy { $0.count == 4 })
            let limit = DocumentCipher.chunkSize + (category.isSensitive ? DocumentCipher.overhead : 0)
            XCTAssertTrue(chunks.allSatisfy { $0.bytes.count <= limit }, "No stored value exceeds one chunk")
            if !category.isSensitive { XCTAssertEqual(chunks.map(\.bytes).reduce(Data(), +), plaintext) }
            let bytes = try await store.contents(ofDocument: doc.id).bytes; XCTAssertEqual(bytes, plaintext)
        }
        try await store.close()
    }

    func testFileWithMissingChunkIsNotAvailableUntilComplete() async throws {
        let store = try await LibraryStore.open(directory: directory())
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Manual", category: .manual), source: .file(Self.pdf(size: 2 * DocumentCipher.chunkSize + 10), filename: "m.pdf")))
        // Simulate CloudKit having delivered only some chunk records so far.
        try await mutateChunks(store, documentID: doc.id) { row, index, context in if index == 1 { context.delete(row) } }
        let partial = try await store.document(id: doc.id); XCTAssertEqual(partial?.availability, .awaitingDownload)
        await expectError(.contentNotDownloaded) { try await store.contents(ofDocument: doc.id) }
        let status = try await store.cloudStatus(ofDocument: doc.id); XCTAssertEqual(status, .localOnly)
        try await store.close()
    }

    func testInterruptedChunkWriteIsRemovedOnlyByTheDeviceThatStartedIt() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d)
        let documentID = UUID(), ownVersion = UUID().uuidString, remoteVersion = UUID().uuidString
        try await store.context.perform { [store] in
            for (version, marked) in [(ownVersion, true), (remoteVersion, false)] {
                let row = NSEntityDescription.insertNewObject(forEntityName: LibraryModel.documentContentEntity, into: store.context)
                for (key, value) in ["key": "documentContent:\(documentID):\(version):0", "rowID": UUID().uuidString, "documentID": documentID.uuidString,
                                     "versionID": version, "checksum": "abc", "chunkChecksum": "abc"] { row.setValue(value, forKey: key) }
                row.setValue(Int64(0), forKey: "chunkIndex"); row.setValue(Int64(1), forKey: "chunkCount"); row.setValue(Data([1]), forKey: "bytes")
                if marked { try store.putMeta("pendingDocumentVersion:\(documentID.uuidString):\(version)", Data("abc".utf8)) }
            }
            try store.context.save()
        }
        try await store.close()
        let reopened = try await LibraryStore.open(directory: d)
        let remaining = try await reopened.context.perform { [reopened] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentContentEntity)
            return try reopened.context.fetch(request).compactMap { $0.value(forKey: "versionID") as? String }
        }
        XCTAssertEqual(remaining, [remoteVersion], "Chunks still arriving from another device are kept")
        let marker = try await reopened.metadata("pendingDocumentVersion:\(documentID.uuidString):\(ownVersion)"); XCTAssertNil(marker)
        try await reopened.close()
    }

    func testSensitiveDocumentIsEncryptedInTheStoreAndRoundTripsAcrossRelaunch() async throws {
        let d = try directory()
        var plaintext = Data("%PDF-1.7\nPOLICY-NUMBER-RR-123456789\n".utf8)
        plaintext.append(Self.pdf(size: 2_600_000))
        let store = try await LibraryStore.open(directory: d)
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Insurance", category: .insurance),
                                                            source: .fileAt(try temporaryFile(plaintext), filename: "policy.pdf")))
        XCTAssertEqual(doc.metadata.protection, .endToEnd)
        let chunks = try await storedChunks(store, documentID: doc.id)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.encryption == DocumentCipher.scheme && $0.key?.count == 32 })
        XCTAssertEqual(Set(chunks.compactMap(\.key)).count, 1, "One key per stored version")
        for chunk in chunks { XCTAssertNil(chunk.bytes.range(of: Data("POLICY-NUMBER-RR-123456789".utf8)), "Plaintext must not reach the mirrored attribute") }
        try await store.close()

        let reopened = try await LibraryStore.open(directory: d)
        let inMemory = try await reopened.contents(ofDocument: doc.id).bytes; XCTAssertEqual(inMemory, plaintext)
        let exported = d.appendingPathComponent("Exports/policy.pdf")
        let file = try await reopened.exportContents(ofDocument: doc.id, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), plaintext); XCTAssertEqual(file, doc.file)
        let listed = try await reopened.document(id: doc.id); XCTAssertEqual(listed?.metadata.protection, .endToEnd)
        try await reopened.close()
    }

    func testLargeStandardFileStreamsFromDiskAndExportsIdentically() async throws {
        let d = try directory(), plaintext = Self.pdf(size: 30_000_000)
        let store = try await LibraryStore.open(directory: d)
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Owner’s manual", category: .manual),
                                                            source: .fileAt(try temporaryFile(plaintext), filename: "manual.pdf")))
        XCTAssertEqual(doc.metadata.protection, .standard)
        let chunks = try await storedChunks(store, documentID: doc.id)
        XCTAssertEqual(chunks.count, DocumentChunkReader.chunkCount(byteCount: plaintext.count)); XCTAssertTrue(chunks.allSatisfy { $0.encryption == nil })
        let exported = d.appendingPathComponent("manual.pdf")
        try await store.exportContents(ofDocument: doc.id, to: exported)
        XCTAssertEqual(DocumentDigest.sha256(try Data(contentsOf: exported)), DocumentDigest.sha256(plaintext))
        let markers = try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.metadataEntity)
            request.predicate = NSPredicate(format: "key BEGINSWITH %@ AND value != nil", "pendingDocumentVersion:")
            return try store.context.count(for: request)
        }
        XCTAssertEqual(markers, 0, "Completed writes leave no pending marker")
        try await store.close()
    }

    func testChoosingSensitiveTypeReEncryptsAndProtectionIsNeverLowered() async throws {
        let store = try await LibraryStore.open(directory: directory()), plaintext = Self.pdf(size: 1_500_000)
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Scan", category: .other), source: .file(plaintext, filename: "scan.pdf")))
        let before = try await storedChunks(store, documentID: doc.id); XCTAssertTrue(before.allSatisfy { $0.encryption == nil })
        let upgraded = try await store.updateDocument(id: doc.id, metadata: DocumentMetadata(title: "Registration", category: .registration))
        XCTAssertEqual(upgraded.metadata.protection, .endToEnd); XCTAssertEqual(upgraded.file, doc.file)
        let after = try await storedChunks(store, documentID: doc.id)
        XCTAssertEqual(after.count, 2, "The plaintext chunks are replaced, not kept alongside")
        XCTAssertTrue(after.allSatisfy { $0.encryption == DocumentCipher.scheme })
        let relabeled = try await store.updateDocument(id: doc.id, metadata: DocumentMetadata(title: "Registration scan", category: .other))
        XCTAssertEqual(relabeled.metadata.protection, .endToEnd)
        let still = try await storedChunks(store, documentID: doc.id); XCTAssertTrue(still.allSatisfy { $0.encryption == DocumentCipher.scheme })
        let bytes = try await store.contents(ofDocument: doc.id).bytes; XCTAssertEqual(bytes, plaintext)

        let optIn = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Title", category: .other, protection: .endToEnd),
                                                              source: .file(Self.png, filename: "title.png")))
        let optInStored = try await storedChunks(store, documentID: optIn.id); XCTAssertEqual(optInStored.first?.encryption, DocumentCipher.scheme)

        // A file that hasn't downloaded to this device can't be re-encrypted, so the change is refused.
        let pending = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Pending", category: .other), source: .file(Self.png, filename: "p.png")))
        try await mutateContent(store, documentID: pending.id) { rows, context in rows.forEach(context.delete) }
        await expectError(.protectionNeedsContent) { try await store.updateDocument(id: pending.id, metadata: DocumentMetadata(title: "Pending", category: .insurance)) }
        let unchanged = try await store.document(id: pending.id); XCTAssertEqual(unchanged?.metadata.protection, .standard)
        try await store.close()
    }

    func testEncryptedChunksDetectTamperingTruncationReorderingWrongKeyAndMoves() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d)
        let plaintext = Self.pdf(size: 3 * DocumentCipher.chunkSize + 100)
        func fresh() async throws -> UUID {
            try await store.addDocument(DocumentDraft(owner: trip, metadata: DocumentMetadata(title: "Reservation", category: .reservation), source: .file(plaintext, filename: "r.pdf"))).id
        }
        func expectRejected(_ id: UUID, _ label: String) async {
            await expectError(.contentIntegrity) { try await store.contents(ofDocument: id) }
            let target = d.appendingPathComponent("out-\(label).pdf")
            await expectError(.contentIntegrity) { try await store.exportContents(ofDocument: id, to: target) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "\(label): nothing partial is left behind")
        }
        let flipped = try await fresh()
        try await mutateChunks(store, documentID: flipped) { row, index, _ in
            guard index == 1, var bytes = row.value(forKey: "bytes") as? Data else { return }
            bytes[bytes.startIndex + 40] ^= 0x01; row.setValue(bytes, forKey: "bytes")
        }
        await expectRejected(flipped, "flipped")

        // Dropping trailing chunks and lowering the count fails: the new last chunk wasn't sealed as final.
        let truncated = try await fresh()
        try await mutateChunks(store, documentID: truncated) { row, index, context in
            if index >= 2 { context.delete(row) } else { row.setValue(Int64(2), forKey: "chunkCount") }
        }
        await expectRejected(truncated, "truncated")

        let reordered = try await fresh(), originals = try await storedChunks(store, documentID: reordered)
        try await mutateChunks(store, documentID: reordered) { row, index, _ in
            if index == 0 { row.setValue(originals[1].bytes, forKey: "bytes") }
            if index == 1 { row.setValue(originals[0].bytes, forKey: "bytes") }
        }
        await expectRejected(reordered, "reordered")

        let wrongKey = try await fresh()
        try await mutateChunks(store, documentID: wrongKey) { row, _, _ in row.setValue(Data(repeating: 7, count: 32), forKey: "contentKey") }
        await expectRejected(wrongKey, "wrong key")

        // Ciphertext moved from another document fails because the document ID is authenticated.
        let target = try await fresh(), source = try await storedChunks(store, documentID: try await fresh())
        try await mutateChunks(store, documentID: target) { row, index, _ in
            row.setValue(source[index].bytes, forKey: "bytes"); row.setValue(source[index].key, forKey: "contentKey")
        }
        await expectRejected(target, "moved between documents")

        let intact = try await fresh()
        let bytes = try await store.contents(ofDocument: intact).bytes; XCTAssertEqual(bytes, plaintext)
        try await store.close()
    }

    func testProtectedLinkImportIsEncrypted() async throws {
        let store = try await LibraryStore.open(directory: directory())
        let link = try await store.addDocument(DocumentDraft(owner: trip, metadata: DocumentMetadata(title: "Booking", category: .reservation), source: .link(URL(string: "https://example.com/b")!)))
        _ = try await store.attachContent(toDocument: link.id, source: .file(try temporaryFile(Self.pdf(size: 5000))), filename: "booking.pdf")
        let stored = try await storedChunks(store, documentID: link.id); XCTAssertEqual(stored.first?.encryption, DocumentCipher.scheme)
        let bytes = try await store.contents(ofDocument: link.id).bytes; XCTAssertEqual(bytes, Self.pdf(size: 5000))
        try await store.close()
    }

    func testSecureDeleteIsEnabledOnTheLibraryStore() async throws {
        let store = try await LibraryStore.open(directory: directory())
        let pragmas = store.coordinator.persistentStores.compactMap { $0.options?[NSSQLitePragmasOption] as? [String: Any] }
        XCTAssertFalse(pragmas.isEmpty)
        XCTAssertTrue(pragmas.allSatisfy { ($0["secure_delete"] as? String) == "1" })
        try await store.close()
    }

    // MARK: Export

    func testExportArchiveContainsLibraryManifestAndVerifiedDocuments() async throws {
        let d = try directory(), store = try await LibraryStore.open(directory: d), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        let manual = Self.pdf(size: 1_200_000), policy = Self.pdf(size: 4000)
        let a = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Manual", category: .manual), source: .file(manual, filename: "manual.pdf")))
        let b = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Policy", category: .insurance), source: .file(policy, filename: "policy.pdf")))
        let c = try await store.addDocument(DocumentDraft(owner: trip, metadata: DocumentMetadata(title: "Booking", category: .reservation), source: .link(URL(string: "https://example.com/b")!)))
        let d4 = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Card", category: .other), source: .file(Self.png, filename: "card.png")))
        try await mutateContent(store, documentID: d4.id) { rows, context in rows.forEach(context.delete) }

        let archive = d.appendingPathComponent("Exports/export.zip")
        let summary = try await store.exportArchive(to: archive)
        XCTAssertEqual(summary, ExportSummary(included: 2, linkOnly: 1, notDownloaded: 1))
        let unzipped = d.appendingPathComponent("Unzipped")
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, unzipped.path]
        try unzip.run(); unzip.waitUntilExit(); XCTAssertEqual(unzip.terminationStatus, 0)
        let root = unzipped.appendingPathComponent("RoamReady Export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        struct Manifest: Decodable { let schemaVersion: Int; let documents: [ExportedDocument] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("documents.json")))
        XCTAssertEqual(manifest.schemaVersion, 1)
        let byID = Dictionary(uniqueKeysWithValues: manifest.documents.map { ($0.id, $0) })
        XCTAssertEqual(byID[c.id]?.status, .linkOnly); XCTAssertEqual(byID[c.id]?.link, URL(string: "https://example.com/b"))
        XCTAssertEqual(byID[d4.id]?.status, .notDownloaded)
        XCTAssertEqual(byID[b.id]?.protection, "endToEnd")
        for (doc, bytes) in [(a, manual), (b, policy)] {
            let entry = try XCTUnwrap(byID[doc.id]); XCTAssertEqual(entry.status, .included)
            let exported = try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(entry.path)))
            XCTAssertEqual(exported, bytes, "Exported files are the verified originals, decrypted when protected")
            XCTAssertEqual(entry.sha256, DocumentDigest.sha256(bytes))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent(LibraryStore.stagingDirectoryName).appendingPathComponent("RoamReady Export").path))
        try await store.close()
    }

    // MARK: Helpers

    private func contentRowCount(_ store: LibraryStore, documentID: UUID) async throws -> Int {
        try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentContentEntity)
            request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
            return try store.context.count(for: request)
        }
    }

    private func mutateContent(_ store: LibraryStore, documentID: UUID, _ change: @escaping @Sendable ([NSManagedObject], NSManagedObjectContext) -> Void) async throws {
        try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LibraryModel.documentContentEntity)
            request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
            change(try store.context.fetch(request), store.context)
            try store.context.save()
        }
    }
}
#endif
