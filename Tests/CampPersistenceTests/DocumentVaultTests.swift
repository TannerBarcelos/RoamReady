#if canImport(CoreData)
import Foundation
import CoreData
import XCTest
import CampCore
@testable import CampPersistence

final class DocumentVaultTests: XCTestCase, @unchecked Sendable {
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
        let trip = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_750_000_000), departure: Date(timeIntervalSince1970: 1_750_086_400), rig: rig)
        return LibrarySnapshot(state: AppState(profile: CamperProfile(rig: rig), trips: [trip], templates: ChecklistFactory.templates(for: rig)), favorites: ["ridb-232447"])
    }
    private func expectError<T>(_ expected: DocumentError, _ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? DocumentError, expected, file: file, line: line) }
    }

    // MARK: Schema

    func testFrozenV2ModelShapeIsUnchanged() {
        func shape(_ model: NSManagedObjectModel, _ configuration: String) -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: model.entities(forConfigurationName: configuration)!.map { entity in
                (entity.name!, entity.attributesByName.values.map { "\($0.name):\($0.attributeType.rawValue)" }.sorted())
            })
        }
        let s = "700", n = "500", b = "1000", flag = "800"
        func base(_ fields: [String: String]) -> [String] {
            (["key:\(s)", "rowID:\(s)", "removed:\(flag)"] + fields.map { "\($0.key):\($0.value)" }).sorted()
        }
        let expected: [String: [String]] = [
            "RR_profile": base(["name": s, "experience": s, "rigKey": s]),
            "RR_rig": base(["id": s, "type": s, "make": s, "model": s, "floorplan": s, "emoji": s, "photoFilename": s, "year": n, "equipment": b]),
            "RR_trip": base(["id": s, "campgroundName": s, "siteNumber": s, "notes": s, "rating": s, "rigKey": s, "campgroundID": s,
                             "planningTimeZoneIdentifier": s, "campgroundTimeZoneIdentifier": s, "latitude": n, "longitude": n,
                             "arrival": n, "departure": n, "position": n, "initialChecklistKeys": b]),
            "RR_checklistItem": base(["id": s, "title": s, "detail": s, "section": s, "status": s, "owner": s, "phase": s, "position": n]),
            "RR_templates": base(["id": s, "sourceURL": s, "version": n, "initialChecklistKeys": b]),
            "RR_photo": base(["id": s, "filename": s, "caption": s, "owner": s, "createdAt": n, "position": n]),
            "RR_asset": base(["filename": s, "checksum": s, "bytes": b]),
            "RR_favorite": base(["campgroundID": s, "saved": flag]),
            "RR_noteRevision": base(["owner": s, "body": s, "createdAt": n])
        ]
        let v2 = ManagedStoreModel.v2()
        XCTAssertEqual(v2.versionIdentifiers, [ManagedStoreModel.v2Identifier])
        XCTAssertEqual(shape(v2, "Library"), expected)
        XCTAssertEqual(shape(v2, "Device"), ["LocalMetadata": ["key:\(s)", "value:\(b)"]])
        XCTAssertEqual(v2.entitiesByName["RR_asset"]?.attributesByName["bytes"]?.allowsExternalBinaryDataStorage, true)
        // v3 must carry every v2 entity unchanged so the store migrates without data changes.
        let v3 = ManagedStoreModel.v3()
        for (name, hash) in v2.entityVersionHashesByName { XCTAssertEqual(v3.entityVersionHashesByName[name], hash, name) }
        XCTAssertNotEqual(v2.versionChecksum, v3.versionChecksum)
        XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: v2, destinationModel: v3))
    }

    func testDocumentEntitiesAreCloudKitCompatibleAndMirrored() throws {
        let model = ManagedStoreModel.make()
        let library = Set(model.entities(forConfigurationName: "Library")!.map(\.name!))
        XCTAssertTrue(library.isSuperset(of: [ManagedStoreModel.documentEntity, ManagedStoreModel.documentContentEntity]))
        for name in [ManagedStoreModel.documentEntity, ManagedStoreModel.documentContentEntity] {
            let entity = try XCTUnwrap(model.entitiesByName[name])
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            XCTAssertTrue(entity.relationshipsByName.isEmpty)
            XCTAssertTrue(entity.attributesByName.values.allSatisfy { $0.isOptional || $0.defaultValue != nil })
        }
        XCTAssertEqual(model.entitiesByName[ManagedStoreModel.documentContentEntity]?.attributesByName["bytes"]?.allowsExternalBinaryDataStorage, true)
        XCTAssertNil(model.entitiesByName[ManagedStoreModel.documentEntity]?.attributesByName["bytes"], "Listings must not fault document bytes")
    }

    // MARK: Persistence

    func testUploadedOriginalBytesSurviveRelaunchWithoutNetwork() async throws {
        let d = try directory()
        let manual = Self.pdf(size: 3_000_000), photo = Self.png
        let issued = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let metadata = DocumentMetadata(title: "Owner’s manual", category: .manual, notes: "Chassis section p. 40", issuedOn: issued, expiresOn: issued.addingTimeInterval(86_400 * 365))
        let store = try await SQLiteStore.open(directory: d)
        let added = try await store.addDocument(DocumentDraft(owner: rig, metadata: metadata, source: .file(manual, filename: "Manual.pdf")))
        let card = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Insurance card", category: .insurance), source: .file(photo, filename: "card.png")))
        XCTAssertEqual(added.availability, .offline)
        XCTAssertEqual(added.file, DocumentFile(filename: "Manual.pdf", contentType: .pdf, byteCount: manual.count, checksum: DocumentDigest.sha256(manual)))
        try await store.close()

        let reopened = try await SQLiteStore.open(directory: d)
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
        let d = try directory(), store = try await SQLiteStore.open(directory: d)
        let rigDoc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Registration", category: .registration), source: .file(Self.pdf(), filename: "reg.pdf")))
        let tripDoc = try await store.addDocument(DocumentDraft(owner: trip, metadata: DocumentMetadata(title: "Site map", category: .reservation), source: .link(URL(string: "https://example.com/map")!)))
        let edited = DocumentMetadata(title: "Registration 2027", category: .registration, notes: "Renew online", expiresOn: Date(timeIntervalSinceReferenceDate: 900_000_000))
        _ = try await store.updateDocument(id: rigDoc.id, metadata: edited)
        await expectError(.missingTitle) { try await store.updateDocument(id: rigDoc.id, metadata: DocumentMetadata(title: " ")) }
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let rigDocs = try await reopened.documents(ownedBy: rig), tripDocs = try await reopened.documents(ownedBy: trip)
        XCTAssertEqual(rigDocs.map(\.id), [rigDoc.id]); XCTAssertEqual(rigDocs.first?.metadata, edited)
        XCTAssertEqual(tripDocs.map(\.id), [tripDoc.id])
        let all = try await reopened.documents(ownedBy: nil); XCTAssertEqual(all.count, 2)
        try await reopened.close()
    }

    func testLinksStayOnlineOnlyUntilContentsAreExplicitlyImported() async throws {
        let d = try directory(), store = try await SQLiteStore.open(directory: d)
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
        let reopened = try await SQLiteStore.open(directory: d)
        let offline = try await reopened.contents(ofDocument: link.id)
        XCTAssertEqual(offline.bytes, Self.png)
        let restored = try await reopened.document(id: link.id); XCTAssertEqual(restored?.link, url)
        try await reopened.close()
    }

    func testInvalidImportsAreRejectedWithoutWritingAnything() async throws {
        let store = try await SQLiteStore.open(directory: directory())
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
        let d = try directory(), store = try await SQLiteStore.open(directory: d)
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
        let reopened = try await SQLiteStore.open(directory: d)
        await expectError(.contentNotDownloaded) { try await reopened.contents(ofDocument: added.id) }
        try await reopened.close()
    }

    func testDeliberateDeletionRemovesBytesAndLeavesIdentityOnlyTombstone() async throws {
        let d = try directory(), store = try await SQLiteStore.open(directory: d)
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Private policy", notes: "Policy #123"), source: .file(Self.pdf(size: 2_000_000), filename: "p.pdf")))
        let keep = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Keep"), source: .file(Self.png, filename: "k.png")))
        try await store.deleteDocument(id: doc.id)
        await expectError(.documentNotFound) { try await store.deleteDocument(id: doc.id) }
        let gone = try await store.document(id: doc.id); XCTAssertNil(gone)
        let remaining = try await contentRowCount(store, documentID: doc.id); XCTAssertEqual(remaining, 0)
        let tombstone = try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: ManagedStoreModel.documentEntity)
            request.predicate = NSPredicate(format: "id == %@", doc.id.uuidString)
            return try store.context.fetch(request).map { [$0.value(forKey: "removed") as? Bool == true, $0.value(forKey: "title") == nil, $0.value(forKey: "notes") == nil] }
        }
        XCTAssertEqual(tombstone, [[true, true, true]])
        await expectError(.duplicateDocument) { try await store.addDocument(DocumentDraft(id: doc.id, owner: rig, metadata: DocumentMetadata(title: "Again"), source: .file(Self.png, filename: "a.png"))) }
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let listed = try await reopened.documents(ownedBy: rig); XCTAssertEqual(listed.map(\.id), [keep.id])
        try await reopened.close()
    }

    func testDuplicateLogicalDocumentRowsReconcileDeterministically() async throws {
        let store = try await SQLiteStore.open(directory: directory())
        let doc = try await store.addDocument(DocumentDraft(owner: rig, metadata: DocumentMetadata(title: "Original"), source: .link(URL(string: "https://example.com")!)))
        try await store.context.perform { [store] in
            let row = NSEntityDescription.insertNewObject(forEntityName: ManagedStoreModel.documentEntity, into: store.context)
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

    // MARK: Migration

    func testV2StoreMigratesExplicitlyPreservingPhotosAndBackup() async throws {
        let d = try directory(); var base = try library()
        let photoBytes = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        base.state.trips[0].photos = [TripPhoto(filename: "photo.jpg", caption: "Lakeside", createdAt: base.state.trips[0].arrival)]
        try await makeV2Store(directory: d, base: base, photo: photoBytes)

        let store = try await SQLiteStore.open(directory: d)
        let migrated = try await store.snapshot(); XCTAssertEqual(migrated, base)
        let photo = try await store.asset(filename: "photo.jpg"); XCTAssertEqual(photo, photoBytes)
        let marker = try await store.metadata("managedSchemaV3")
        XCTAssertEqual(marker.map { String(decoding: $0, as: UTF8.self) }, "migrated-from-\(ManagedStoreModel.v2Identifier)")
        let backup = ManagedStoreMigration.backupURL(in: d)
        let backupMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: backup)
        XCTAssertTrue(ManagedStoreModel.v2().isConfiguration(withName: "Library", compatibleWithStoreMetadata: backupMetadata))
        let libraryMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: d.appendingPathComponent("RoamReadyManaged.sqlite"))
        XCTAssertTrue(ManagedStoreModel.v3().isConfiguration(withName: "Library", compatibleWithStoreMetadata: libraryMetadata))
        let doc = try await store.addDocument(DocumentDraft(owner: .rig(base.state.profile!.rig.id), metadata: DocumentMetadata(title: "Manual"), source: .file(Self.pdf(), filename: "m.pdf")))
        try await store.close()

        let reopened = try await SQLiteStore.open(directory: d)
        let again = try await reopened.snapshot(); XCTAssertEqual(again, base)
        let still = try await reopened.metadata("managedSchemaV3")
        XCTAssertEqual(still.map { String(decoding: $0, as: UTF8.self) }, "migrated-from-\(ManagedStoreModel.v2Identifier)")
        let bytes = try await reopened.contents(ofDocument: doc.id).bytes; XCTAssertEqual(bytes, Self.pdf())
        let photoAgain = try await reopened.asset(filename: "photo.jpg"); XCTAssertEqual(photoAgain, photoBytes)
        try await reopened.close()
    }

    func testInterruptedMigrationIsVerifiedAgainstBackupAndFailsClosedOnMismatch() async throws {
        let d = try directory(), base = try library()
        try await makeV2Store(directory: d, base: base, photo: Data([1, 2, 3]))
        var store = try await SQLiteStore.open(directory: d)
        // Simulate termination after Core Data converted the store but before verification.
        try await store.setMetadata("managedSchemaV3", value: nil)
        try await store.close()
        store = try await SQLiteStore.open(directory: d)
        let resumed = try await store.metadata("managedSchemaV3")
        XCTAssertEqual(resumed.map { String(decoding: $0, as: UTF8.self) }, "migrated-from-\(ManagedStoreModel.v2Identifier)")
        // Now diverge from the backup and interrupt again: verification must refuse to open.
        try await store.setMetadata("managedSchemaV3", value: nil)
        try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: LegacyStoreModel.name(.trip))
            try store.context.fetch(request).forEach { $0.setValue("Changed outside migration", forKey: "notes") }
            try store.context.save()
        }
        try await store.close()
        for _ in 0..<2 {
            do { _ = try await SQLiteStore.open(directory: d); XCTFail("Expected verification failure") }
            catch { XCTAssertEqual(error as? ManagedStoreMigrationError, .verificationFailed) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ManagedStoreMigration.backupURL(in: d).path))
    }

    func testUnknownStoreVersionIsRefusedAndLeftUntouched() async throws {
        let d = try directory()
        let future = ManagedStoreModel.v2()
        let trip = try XCTUnwrap(future.entitiesByName["RR_trip"])
        let added = NSAttributeDescription(); added.name = "futureField"; added.attributeType = .stringAttributeType; added.isOptional = true
        trip.properties.append(added)
        try await makeStore(directory: d, model: future) { _ in }
        let url = d.appendingPathComponent("RoamReadyManaged.sqlite")
        do { _ = try await SQLiteStore.open(directory: d); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? ManagedStoreMigrationError, .unrecognizedStoreVersion) }
        // Still in the newer format: nothing was inferred or converted.
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        XCTAssertTrue(future.isConfiguration(withName: "Library", compatibleWithStoreMetadata: metadata))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedStoreMigration.backupURL(in: d).path))
    }

    func testNewStoreRecordsCurrentSchemaWithoutBackup() async throws {
        let d = try directory(), store = try await SQLiteStore.open(directory: d)
        let marker = try await store.metadata("managedSchemaV3")
        XCTAssertEqual(marker.map { String(decoding: $0, as: UTF8.self) }, "created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedStoreMigration.backupURL(in: d).path))
        try await store.close()
    }

    // MARK: Helpers

    private func contentRowCount(_ store: SQLiteStore, documentID: UUID) async throws -> Int {
        try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: ManagedStoreModel.documentContentEntity)
            request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
            return try store.context.count(for: request)
        }
    }

    private func mutateContent(_ store: SQLiteStore, documentID: UUID, _ change: @escaping @Sendable ([NSManagedObject], NSManagedObjectContext) -> Void) async throws {
        try await store.context.perform { [store] in
            let request = NSFetchRequest<NSManagedObject>(entityName: ManagedStoreModel.documentContentEntity)
            request.predicate = NSPredicate(format: "documentID == %@", documentID.uuidString)
            change(try store.context.fetch(request), store.context)
            try store.context.save()
        }
    }

    /// Writes a store exactly as a build using `model` would: separate Library and Device files.
    private func makeStore(directory: URL, model: NSManagedObjectModel, populate: @escaping @Sendable (NSManagedObjectContext) throws -> Void) async throws {
        let container = NSPersistentContainer(name: "Previous", managedObjectModel: model)
        let library = NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReadyManaged.sqlite"))
        library.configuration = "Library"; library.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        let device = NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReadyDevice.sqlite"))
        device.configuration = "Device"
        for description in [device, library] {
            container.persistentStoreDescriptions = [description]
            try await SQLiteStore.loadStores(container)
        }
        let context = container.newBackgroundContext()
        try await context.perform {
            try populate(context)
            if context.hasChanges { try context.save() }
        }
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }

    private func makeV2Store(directory: URL, base: LibrarySnapshot, photo: Data) async throws {
        let docs = Array(try RecordProjection.documents(base).values)
        try await makeStore(directory: directory, model: ManagedStoreModel.v2()) { context in
            for doc in docs {
                let row = NSEntityDescription.insertNewObject(forEntityName: LegacyStoreModel.name(doc.kind), into: context)
                row.setValue(doc.key, forKey: "key"); row.setValue(UUID().uuidString, forKey: "rowID")
                for (field, value) in doc.fields {
                    switch value {
                    case .string(let v): row.setValue(v, forKey: field)
                    case .number(let v): row.setValue(v, forKey: field)
                    case .bool(let v): row.setValue(v, forKey: field)
                    case .null: break
                    default: row.setValue(try JSONEncoder().encode(value), forKey: field)
                    }
                }
            }
            let asset = NSEntityDescription.insertNewObject(forEntityName: LegacyStoreModel.name(.asset), into: context)
            asset.setValue("asset:photo.jpg", forKey: "key"); asset.setValue(UUID().uuidString, forKey: "rowID")
            asset.setValue("photo.jpg", forKey: "filename"); asset.setValue(DocumentDigest.sha256(photo), forKey: "checksum")
            asset.setValue(photo, forKey: "bytes")
            for (key, value) in ["managedMigrationV2": "no-source", "legacyMigrationV1": "complete"] {
                let meta = NSEntityDescription.insertNewObject(forEntityName: "LocalMetadata", into: context)
                meta.setValue(key, forKey: "key"); meta.setValue(Data(value.utf8), forKey: "value")
            }
        }
    }
}
#endif
