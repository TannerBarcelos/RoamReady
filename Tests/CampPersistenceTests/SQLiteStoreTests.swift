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
        let rig = Rig(make: "Test", model: "Trailer", year: 2024, lengthFeet: 23.5, slideCount: 1, axleCount: 2, hasBunkhouse: true)
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

    func testStoreCreatedBeforeRigDetailsMigratesAndThenPersistsThem() async throws {
        let d = try directory()
        let oldRig = Rig(type: .travelTrailer, make: "Forest River", model: "No Boundaries NB19.5", year: 2024, photoFilename: "rig.jpg")
        let old = LibrarySnapshot(state: AppState(profile: CamperProfile(name: "Camper", rig: oldRig)))
        // Build the previous managed (v2) model, without the rig detail attributes, and write rows with it.
        let v2 = ManagedStoreModel.make(fields: LegacyStoreModel.fields)
        XCTAssertNil(v2.entitiesByName[LegacyStoreModel.name(.rig)]?.attributesByName["lengthFeet"])
        let container = NSPersistentContainer(name: "RoamReadyV2", managedObjectModel: v2)
        let library = NSPersistentStoreDescription(url: d.appendingPathComponent("RoamReadyManaged.sqlite"))
        library.configuration = "Library"
        library.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        let device = NSPersistentStoreDescription(url: d.appendingPathComponent("RoamReadyDevice.sqlite"))
        device.configuration = "Device"
        for description in [device, library] {
            container.persistentStoreDescriptions = [description]
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                container.loadPersistentStores { _, error in if let error { c.resume(throwing: error) } else { c.resume() } }
            }
        }
        let context = container.newBackgroundContext()
        try await context.perform {
            for doc in try RecordProjection.documents(old).values {
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
            try context.save()
        }
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }

        // Opening with the current model migrates in place; the existing rig, photo reference, and emoji survive.
        let store = try await SQLiteStore.open(directory: d)
        let migrated = try await store.snapshot()
        XCTAssertEqual(migrated, old)
        XCTAssertNil(migrated.state.profile?.rig.lengthFeet)
        XCTAssertEqual(migrated.state.profile?.rig.photoFilename, "rig.jpg")
        XCTAssertEqual(migrated.state.profile?.rig.emoji, oldRig.emoji)

        var completed = migrated
        completed.state.profile?.rig.lengthFeet = 19.5
        completed.state.profile?.rig.setSlideCount(0)
        completed.state.profile?.rig.axleCount = 1
        completed.state.profile?.rig.hasBunkhouse = false
        try await store.save(from: migrated, to: completed)
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored, completed)
        XCTAssertEqual(restored.state.profile?.rig.slideCount, 0)
        XCTAssertEqual(restored.state.profile?.rig.hasBunkhouse, false)

        // Clearing an optional detail removes it rather than leaving a stale value.
        var cleared = restored
        cleared.state.profile?.rig.axleCount = nil
        try await reopened.save(from: restored, to: cleared)
        let afterClear = try await reopened.snapshot()
        XCTAssertNil(afterClear.state.profile?.rig.axleCount)
        try await reopened.close()
    }
    func testRigDetailAttributesAreOptionalInTheMirroredModelOnly() {
        let rig = ManagedStoreModel.make().entitiesByName[LegacyStoreModel.name(.rig)]!
        for name in ["lengthFeet", "slideCount", "axleCount", "hasBunkhouse"] {
            XCTAssertEqual(rig.attributesByName[name]?.isOptional, true, name)
        }
        let frozen = LegacyStoreModel.v1().entitiesByName[LegacyStoreModel.name(.rig)]!
        XCTAssertNil(frozen.attributesByName["lengthFeet"], "The frozen v1 import model must not change")
    }

    func testUnreferencedPhotosArePurgedOnlyAfterTheLastReferenceGoes() async throws {
        let d = try directory()
        let media = d.appendingPathComponent("Media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let oldBytes = Data([1, 1, 1]), newBytes = Data([2, 2, 2]), tripBytes = Data([3, 3, 3])
        try oldBytes.write(to: media.appendingPathComponent("old.jpg"))
        try newBytes.write(to: media.appendingPathComponent("new.jpg"))
        try tripBytes.write(to: media.appendingPathComponent("trip.jpg"))
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: media.appendingPathComponent(name).path) }
        let rig = Rig(make: "Forest River", model: "No Boundaries NB19.5", year: 2024, photoFilename: "old.jpg", lengthFeet: 19.5)
        let first = LibrarySnapshot(state: AppState(profile: CamperProfile(rig: rig)))
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: first)
        let stored = try await store.asset(filename: "old.jpg"); XCTAssertEqual(stored, oldBytes)

        // Replacing the rig photo purges the old bytes and local copy.
        var replaced = first; replaced.state.profile?.rig.photoFilename = "new.jpg"
        try await store.save(from: first, to: replaced)
        let purgedOld = try await store.asset(filename: "old.jpg"); XCTAssertNil(purgedOld)
        XCTAssertFalse(exists("old.jpg"))
        let keptNew = try await store.asset(filename: "new.jpg"); XCTAssertEqual(keptNew, newBytes)

        // A trip's rig snapshot keeps the photo after the profile switches to emoji.
        var withTrip = replaced
        var trip = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_750_000_000),
                                   departure: Date(timeIntervalSince1970: 1_750_086_400), rig: replaced.state.profile!.rig)
        trip.photos = [TripPhoto(filename: "trip.jpg", createdAt: trip.arrival)]
        withTrip.state.trips = [trip]
        try await store.save(from: replaced, to: withTrip)
        var emoji = withTrip; emoji.state.profile?.rig.photoFilename = nil
        try await store.save(from: withTrip, to: emoji)
        let snapshotPhoto = try await store.asset(filename: "new.jpg"); XCTAssertEqual(snapshotPhoto, newBytes)
        XCTAssertTrue(exists("new.jpg"))

        // Removing a trip photo purges it; the trip and its rig photo stay.
        var noTripPhoto = emoji; noTripPhoto.state.trips[0].photos = []
        try await store.save(from: emoji, to: noTripPhoto)
        let purgedTripPhoto = try await store.asset(filename: "trip.jpg"); XCTAssertNil(purgedTripPhoto)
        XCTAssertFalse(exists("trip.jpg"))
        let stillNew = try await store.asset(filename: "new.jpg"); XCTAssertEqual(stillNew, newBytes)

        // Deleting the trip releases the last reference to the rig photo.
        var noTrip = noTripPhoto; noTrip.state.trips = []
        try await store.save(from: noTripPhoto, to: noTrip)
        let purgedNew = try await store.asset(filename: "new.jpg"); XCTAssertNil(purgedNew)
        XCTAssertFalse(exists("new.jpg"))
        try await store.close()

        let reopened = try await SQLiteStore.open(directory: d)
        let restored = try await reopened.snapshot(); XCTAssertEqual(restored, noTrip)
        try await reopened.close()
    }
    func testPurgedPhotoReferencedAgainIsRevivedFromTheLocalCopy() async throws {
        let d = try directory()
        let media = d.appendingPathComponent("Media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let bytes = Data([4, 5, 6])
        let rig = Rig(make: "Jayco", model: "Eagle", year: 2025, photoFilename: "rig.jpg", lengthFeet: 38)
        try bytes.write(to: media.appendingPathComponent("rig.jpg"))
        let withPhoto = LibrarySnapshot(state: AppState(profile: CamperProfile(rig: rig)))
        var withoutPhoto = withPhoto; withoutPhoto.state.profile?.rig.photoFilename = nil
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: withPhoto)
        try await store.save(from: withPhoto, to: withoutPhoto)
        let purged = try await store.asset(filename: "rig.jpg"); XCTAssertNil(purged)
        try bytes.write(to: media.appendingPathComponent("rig.jpg"))
        try await store.save(from: withoutPhoto, to: withPhoto)
        let revived = try await store.asset(filename: "rig.jpg"); XCTAssertEqual(revived, bytes)
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
