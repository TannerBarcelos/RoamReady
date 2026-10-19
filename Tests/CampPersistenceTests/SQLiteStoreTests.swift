#if canImport(CoreData)
import Foundation
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
    func testSQLiteSaveCloseReopenAndExport() async throws {
        let d = try directory(), original = try library()
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: original)
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored, original)
        let header = try Data(contentsOf: d.appendingPathComponent("RoamReady.sqlite")).prefix(16)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "SQLite format 3\0")
        let export = d.appendingPathComponent("Exports/library.json")
        try await reopened.export(to: export)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        try await reopened.close()
    }
    func testLegacyMigrationPreservesArchiveAssetsAndDoesNotDuplicateOnRelaunch() async throws {
        let d = try directory(); var original = try library()
        let media = d.appendingPathComponent("Media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: media.appendingPathComponent("photo.jpg"))
        original.state.trips[0].photos = [TripPhoto(filename: "photo.jpg", createdAt: Date(timeIntervalSince1970: 1_750_000_000))]
        let legacy = FileAppStore(directory: d); try await legacy.save(original.state)
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
    func testStaleSnapshotDoesNotEraseDownloadedFieldAndNotesHaveRevisions() async throws {
        let d = try directory(), baseline = try library()
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: baseline)
        let pending = try await store.pending(limit: 1000)
        var remote = try XCTUnwrap(pending.first { $0.record.kind == .trip }?.record)
        remote.fields["notes"] = .string("Remote notes"); remote.versions["notes"] = .init(counter: 900, writer: "second-device")
        try await store.receive([(remote, nil)])
        var desired = baseline; desired.state.trips[0].siteNumber = "42"
        try await store.save(from: baseline, to: desired)
        var result = try await store.snapshot()
        XCTAssertEqual(result.state.trips[0].notes, "Remote notes")
        XCTAssertEqual(result.state.trips[0].siteNumber, "42")
        let previous = result; result.state.trips[0].notes = "Local notes"
        try await store.save(from: previous, to: result)
        let history = try await store.noteRevisions(tripID: result.state.trips[0].id)
        XCTAssertTrue(history.contains { $0.text == "Remote notes" }); XCTAssertTrue(history.contains { $0.text == "Local notes" })
        try await store.close()
    }
    func testUploadAcknowledgementCannotClearNewerEdit() async throws {
        let store = try await SQLiteStore.open(directory: directory()), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        let originalPending = try await store.pending(limit: 1000)
        let old = try XCTUnwrap(originalPending.first { $0.record.kind == .trip })
        var edited = base; edited.state.trips[0].siteNumber = "new"
        try await store.save(from: base, to: edited)
        try await store.acknowledge(key: old.record.key, kind: .trip, revision: old.revision)
        let pending = try await store.pending(limit: 1000)
        XCTAssertTrue(pending.contains { $0.record.key == old.record.key })
        try await store.close()
    }
    func testDeleteWinsAndFavoriteCanBeSavedAgain() async throws {
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
    func testInterruptedFirstDownloadDoesNotBlockExistingLibraryAfterReopen() async throws {
        let d = try directory(), base = try library()
        let store = try await SQLiteStore.open(directory: d)
        try await store.save(from: LibrarySnapshot(), to: base)
        let sender = try await SQLiteStore.open(directory: directory())
        var new = try library(); new.state.trips[0].campgroundName = "New remote trip"
        try await sender.save(from: LibrarySnapshot(), to: new)
        let outgoing = try await sender.pending(limit: 1000)
        let parent = try XCTUnwrap(outgoing.first { $0.record.kind == .trip })
        try await store.receive([(parent.record, nil)], token: Data("page-one".utf8))
        let initial = try await store.snapshot(); XCTAssertEqual(initial, base)
        try await store.close()
        let reopened = try await SQLiteStore.open(directory: d)
        let offline = try await reopened.snapshot(); XCTAssertEqual(offline, base)
        let staged = try await reopened.hasStagedDownloads(); XCTAssertTrue(staged)
        let token = try await reopened.metadata("cloudToken"); XCTAssertEqual(token, Data("page-one".utf8))
        let children = outgoing.filter { $0.record.key != parent.record.key && $0.record.kind != .profile && $0.record.kind != .templates }
        try await reopened.receive(children.map { ($0.record, $0.asset) })
        let complete = try await reopened.snapshot()
        XCTAssertEqual(Set(complete.state.trips.map(\.id)), Set(base.state.trips.map(\.id) + new.state.trips.map(\.id)))
        let stillStaged = try await reopened.hasStagedDownloads(); XCTAssertFalse(stillStaged)
        try await reopened.close(); try await sender.close()
    }
    func testInvalidRemotePageRollsBackTokenAndRecords() async throws {
        let store = try await SQLiteStore.open(directory: directory()), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        try await store.setMetadata("cloudToken", value: Data("before".utf8))
        let fields: [String: RecordValue] = ["filename": .string("wrong.jpg"), "checksum": .string("bad-checksum")]
        let asset = ReplicaRecord(key: "asset:wrong.jpg", kind: .asset, fields: fields, versions: fields.mapValues { _ in .init(counter: 100, writer: "remote") })
        do { try await store.receive([(asset, Data([1, 2]))], token: Data("after".utf8)); XCTFail("Expected invalid asset") } catch { }
        let token = try await store.metadata("cloudToken"); XCTAssertEqual(token, Data("before".utf8))
        let snapshot = try await store.snapshot(); XCTAssertEqual(snapshot, base)
        try await store.close()
    }

    func testRigDeletionBeforeTripDeletionStagesWithoutBlockingTheNextPage() async throws {
        let store = try await SQLiteStore.open(directory: directory()), base = try library()
        try await store.save(from: LibrarySnapshot(), to: base)
        let pending = try await store.pending(limit: 1000)
        let trip = try XCTUnwrap(pending.first { $0.record.kind == .trip }?.record)
        let rigKey = try XCTUnwrap(trip.fields["rigKey"]?.string)
        var rig = try XCTUnwrap(pending.first { $0.record.key == rigKey }?.record)
        rig.deletion = .init(counter: 100, writer: "remote")
        try await store.receive([(rig, nil)], token: Data("rig-page".utf8))
        let retained = try await store.snapshot(); XCTAssertEqual(retained, base)
        let token = try await store.metadata("cloudToken"); XCTAssertEqual(token, Data("rig-page".utf8))
        var removed = trip; removed.deletion = .init(counter: 101, writer: "remote")
        try await store.receive([(removed, nil)], token: Data("trip-page".utf8))
        let after = try await store.snapshot(); XCTAssertTrue(after.state.trips.isEmpty)
        let staged = try await store.hasStagedDownloads(); XCTAssertFalse(staged)
        try await store.close()
    }

}
#endif
