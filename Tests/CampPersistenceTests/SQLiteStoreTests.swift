#if canImport(CoreData)
import Foundation
import CoreData
import XCTest
import CampCore
@testable import CampPersistence

final class SQLiteStoreTests: XCTestCase, @unchecked Sendable {
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
    func testManagedSQLiteSaveCloseReopenAndExport() async throws {
        let d = try directory(), original = try library()
        let store = try await SQLiteStore.open(directory: d)
        XCTAssertFalse(store.cloudEnabled)
        try await store.save(from: LibrarySnapshot(), to: original)
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored, original)
        let header = try Data(contentsOf: d.appendingPathComponent("RoamReadyManaged.sqlite")).prefix(16)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "SQLite format 3\0")
        let export = d.appendingPathComponent("Exports/library.json")
        try await reopened.export(to: export)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        try await reopened.close()
    }
    func testMirroredModelMeetsCloudKitRequirementsAndKeepsMetadataLocal() {
        let model = ManagedStoreModel.make()
        let mirrored = model.entities(forConfigurationName: "Library")!
        XCTAssertEqual(mirrored.count, RecordKind.allCases.count)
        XCTAssertFalse(mirrored.contains { $0.name == "LocalMetadata" })
        XCTAssertEqual(model.entities(forConfigurationName: "Device")?.map(\.name), ["LocalMetadata"])
        for entity in mirrored {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
            XCTAssertTrue(entity.attributesByName.values.allSatisfy { $0.isOptional || $0.defaultValue != nil })
            XCTAssertNil(entity.attributesByName["clocks"])
            XCTAssertNil(entity.attributesByName["dirty"])
        }
        XCTAssertEqual(mirrored.first { $0.name == "RR_asset" }?.attributesByName["bytes"]?.allowsExternalBinaryDataStorage, true)
    }
    func testLegacyJSONMigrationPreservesArchiveAssetsAndIsIdempotent() async throws {
        let d = try directory(); var original = try library()
        let media = d.appendingPathComponent("Media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: media.appendingPathComponent("photo.jpg"))
        original.state.trips[0].photos = [TripPhoto(filename: "photo.jpg", createdAt: original.state.trips[0].arrival)]
        try await FileAppStore(directory: d).save(original.state)
        let source = d.appendingPathComponent("camp-state.json"), oldBytes = try Data(contentsOf: source)
        let store = try await SQLiteStore.open(directory: d)
        let imported = try await store.migrateLegacy(archiveURL: source, favorites: original.favorites)
        XCTAssertEqual(imported, original)
        let second = try await store.migrateLegacy(archiveURL: source, favorites: [])
        XCTAssertEqual(second, original)
        let photo = try await store.asset(filename: "photo.jpg")
        XCTAssertEqual(photo, bytes); XCTAssertEqual(try Data(contentsOf: source), oldBytes)
        try await store.close()
    }
    func testCorruptLegacyFileDoesNotMarkMigrationComplete() async throws {
        let d = try directory(), source = d.appendingPathComponent("camp-state.json")
        try Data("invalid".utf8).write(to: source)
        let store = try await SQLiteStore.open(directory: d)
        do { _ = try await store.migrateLegacy(archiveURL: source, favorites: []); XCTFail("Expected migration failure") } catch { }
        let marker = try await store.metadata("legacyMigrationV1")
        XCTAssertNil(marker); XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "invalid")
        try await store.close()
    }
    func testStaleSnapshotPreservesUnrelatedChangesAndNoteHistory() async throws {
        let store = try await SQLiteStore.open(directory: directory()), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        var other = base; other.state.trips[0].notes = "Other device notes"
        try await store.save(from: base, to: other)
        var desired = base; desired.state.trips[0].siteNumber = "42"
        try await store.save(from: base, to: desired)
        var result = try await store.snapshot()
        XCTAssertEqual(result.state.trips[0].notes, "Other device notes")
        XCTAssertEqual(result.state.trips[0].siteNumber, "42")
        let previous = result; result.state.trips[0].notes = "Local notes"
        try await store.save(from: previous, to: result)
        let history = try await store.noteRevisions(tripID: result.state.trips[0].id)
        XCTAssertTrue(history.contains { $0.text == "Other device notes" }); XCTAssertTrue(history.contains { $0.text == "Local notes" })
        try await store.close()
    }
    func testSoftDeleteWinsOverStaleEditAndFavoriteCanBeSavedAgain() async throws {
        let store = try await SQLiteStore.open(directory: directory()), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        var deleted = base; deleted.state.trips = []; deleted.favorites = []
        try await store.save(from: base, to: deleted)
        var stale = base; stale.state.trips[0].notes = "Stale offline edit"
        try await store.save(from: base, to: stale)
        var state = try await store.snapshot(); XCTAssertTrue(state.state.trips.isEmpty)
        let before = state; state.favorites = base.favorites
        try await store.save(from: before, to: state)
        let after = try await store.snapshot(); XCTAssertEqual(after.favorites, base.favorites)
        try await store.close()
    }
    func testManagedAssetSurvivesMissingMediaCacheAndRelaunch() async throws {
        let d = try directory(); var base = try library()
        let media = d.appendingPathComponent("Media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let bytes = Data(repeating: 37, count: 2_000_000)
        try bytes.write(to: media.appendingPathComponent("photo.jpg"))
        base.state.trips[0].photos = [TripPhoto(filename: "photo.jpg", createdAt: base.state.trips[0].arrival)]
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: base)
        try await store.close(); try FileManager.default.removeItem(at: media)
        let reopened = try await SQLiteStore.open(directory: d)
        let restored = try await reopened.asset(filename: "photo.jpg")
        XCTAssertEqual(restored, bytes)
        let snapshot = try await reopened.snapshot(); XCTAssertEqual(snapshot, base)
        try await reopened.close()
    }
    func testPartialManagedImportUsesDurableCoherentProjectionAfterRelaunch() async throws {
        let d = try directory(), base = try library(), remote = try library()
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: base)
        let docs = try RecordProjection.documents(remote)
        let trip = try XCTUnwrap(docs.values.first { $0.kind == .trip })
        var parent = trip
        let required = docs.values.filter { $0.kind == .checklistItem && $0.fields["owner"]?.string == trip.key }.map { RecordValue.string($0.key) }
        parent.fields["initialChecklistKeys"] = .array(required)
        try await insertManaged([parent], into: store)
        let partial = try await store.snapshot(); XCTAssertEqual(partial, base)
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let offline = try await reopened.snapshot(); XCTAssertEqual(offline, base)
        try await insertManaged(docs.values.filter { $0.key != trip.key && $0.kind != .profile && $0.kind != .templates }, into: reopened)
        let completed = try await reopened.snapshot()
        XCTAssertEqual(Set(completed.state.trips.map(\.id)), Set(base.state.trips.map(\.id) + remote.state.trips.map(\.id)))
        try await reopened.close()
    }
    func testLocalEditsAndNewTripRemainVisibleDuringUnrelatedPartialImport() async throws {
        let d = try directory(), base = try library(), remote = try library()
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: base)
        var parent = try XCTUnwrap(RecordProjection.documents(remote).values.first { $0.kind == .trip })
        parent.fields["initialChecklistKeys"] = .array([.string("checklistItem:not-arrived")])
        try await insertManaged([parent], into: store)
        var edited = base; edited.state.trips[0].notes = "Saved while another trip downloads"
        edited.state.trips.append(try library().state.trips[0])
        try await store.save(from: base, to: edited)
        let visible = try await store.snapshot(); XCTAssertEqual(visible, edited)
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let offline = try await reopened.snapshot(); XCTAssertEqual(offline, edited)
        try await reopened.close()
    }
    func testDuplicateLogicalRowsReconcileWithoutUniqueConstraints() async throws {
        let store = try await SQLiteStore.open(directory: directory()), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        let trip = try XCTUnwrap(RecordProjection.documents(base).values.first { $0.kind == .trip })
        var duplicate = trip; duplicate.fields["siteNumber"] = .string("Chosen duplicate")
        try await insertManaged([duplicate], into: store, rowID: "000-first")
        let result = try await store.snapshot()
        XCTAssertEqual(result.state.trips.count, 1); XCTAssertEqual(result.state.trips[0].siteNumber, "Chosen duplicate")
        try await store.close()
    }
    func testMissingLegacyPhotoDoesNotDiscardTrip() async throws {
        let d = try directory(); var base = try library()
        base.state.trips[0].photos = [TripPhoto(filename: "missing.jpg", createdAt: base.state.trips[0].arrival)]
        try await FileAppStore(directory: d).save(base.state)
        let store = try await SQLiteStore.open(directory: d)
        let migrated = try await store.migrateLegacy(archiveURL: d.appendingPathComponent("camp-state.json"), favorites: base.favorites)
        XCTAssertEqual(migrated, base)
        let bytes = try await store.asset(filename: "missing.jpg"); XCTAssertNil(bytes)
        try await store.close()
    }
    func testPreviousSQLiteMigrationRetainsAssetsNotesAndSource() async throws {
        let d = try directory(), base = try library()
        try await makePreviousStore(directory: d, base: base)
        let store = try await SQLiteStore.open(directory: d)
        let imported = try await store.snapshot(); XCTAssertEqual(imported, base)
        let asset = try await store.asset(filename: "old.jpg"); XCTAssertEqual(asset, Data([7, 8, 9]))
        let notes = try await store.noteRevisions(tripID: base.state.trips[0].id); XCTAssertEqual(notes.first?.text, "Retained revision")
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("RoamReady.sqlite").path))
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let second = try await reopened.snapshot(); XCTAssertEqual(second, base)
        try await reopened.close()
    }
    func testIncompletePreviousSyncPreservesUsableLibraryAndSource() async throws {
        let d = try directory(), base = try library()
        try await makePreviousStore(directory: d, base: base, staged: true)
        let store = try await SQLiteStore.open(directory: d)
        let imported = try await store.snapshot(); XCTAssertEqual(imported, base)
        let notice = try await store.metadata("migrationNotice"); XCTAssertNotNil(notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("RoamReady.sqlite").path))
        try await store.close()
    }

    private func insertManaged(_ docs: [ReplicaRecord], into store: SQLiteStore, rowID: String = UUID().uuidString) async throws {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = store.coordinator
        try await context.perform {
            for doc in docs {
                let row = NSEntityDescription.insertNewObject(forEntityName: LegacyStoreModel.name(doc.kind), into: context)
                row.setValue(doc.key, forKey: "key"); row.setValue(rowID, forKey: "rowID")
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
            try context.save()
        }
    }
    private func makePreviousStore(directory: URL, base: LibrarySnapshot, staged: Bool = false) async throws {
        let container = NSPersistentContainer(name: "Previous", managedObjectModel: LegacyStoreModel.v1())
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: directory.appendingPathComponent("RoamReady.sqlite"))]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            container.loadPersistentStores { _, error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        let context = container.newBackgroundContext()
        try await context.perform {
            var docs = Array(try RecordProjection.documents(base).values)
            docs.append(ReplicaRecord(key: "asset:old.jpg", kind: .asset, fields: ["filename": .string("old.jpg")]))
            docs.append(ReplicaRecord(key: "noteRevision:old", kind: .noteRevision, fields: ["owner": .string("trip:\(base.state.trips[0].id)"), "body": .string("Retained revision"), "createdAt": .number(10)]))
            struct Clocks: Encodable { let versions: [String: FieldVersion]; let deletion: FieldVersion? = nil }
            for doc in docs {
                let row = NSEntityDescription.insertNewObject(forEntityName: LegacyStoreModel.name(doc.kind), into: context)
                row.setValue(doc.key, forKey: "key")
                row.setValue(try JSONEncoder().encode(Clocks(versions: doc.fields.mapValues { _ in .init(counter: 1, writer: "previous") })), forKey: "clocks")
                for (field, value) in doc.fields {
                    switch value {
                    case .string(let v): row.setValue(v, forKey: field)
                    case .number(let v): row.setValue(v, forKey: field)
                    case .bool(let v): row.setValue(v, forKey: field)
                    default: row.setValue(try JSONEncoder().encode(value), forKey: field)
                    }
                }
                if doc.kind == .asset { row.setValue(Data([7, 8, 9]), forKey: "bytes") }
            }
            if staged {
                let row = NSEntityDescription.insertNewObject(forEntityName: "IncomingRecord", into: context)
                row.setValue("trip:incomplete", forKey: "key"); row.setValue(Data(), forKey: "payload")
            }
            try context.save()
        }
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
}
#endif
