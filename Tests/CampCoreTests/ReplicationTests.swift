import XCTest
@testable import CampCore

final class ReplicationTests: XCTestCase {
    func testProjectionRoundTripPreservesTripItemAndPhotoOrdering() throws {
        let rig = Rig(make: "Airstream", model: "Classic", year: 2025)
        var a = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_000), departure: Date(timeIntervalSince1970: 2_000), rig: rig)
        a.photos = [TripPhoto(filename: "b.jpg", caption: "First"), TripPhoto(filename: "a.jpg", caption: "Second")]
        let b = try Trip.create(campgroundName: "Watchman", arrival: a.arrival, departure: a.departure, rig: rig)
        let original = LibrarySnapshot(state: AppState(profile: CamperProfile(name: "Camper", rig: rig), trips: [b, a], templates: ChecklistFactory.templates(for: rig)), favorites: ["ridb-1"])
        let records = try RecordProjection.documents(original).values.map { record in
            var r = record; r.versions = r.fields.mapValues { _ in FieldVersion(counter: 1, writer: "A") }; return r
        }
        XCTAssertEqual(try RecordProjection.snapshot(records.reversed()), original)
    }
    func testConcurrentEditsToDifferentFieldsMergeAndConverge() throws {
        var a = ReplicaRecord(key: "checklistItem:x", kind: .checklistItem, fields: ["title": .string("Level"), "status": .string("pending")], versions: ["title": .init(counter: 1, writer: "A"), "status": .init(counter: 1, writer: "A")])
        var b = a
        a.fields["title"] = .string("Level side to side"); a.versions["title"] = .init(counter: 2, writer: "A")
        b.fields["status"] = .string("completed"); b.versions["status"] = .init(counter: 2, writer: "B")
        let merged = try a.merging(b)
        XCTAssertEqual(merged.fields["title"], a.fields["title"])
        XCTAssertEqual(merged.fields["status"], b.fields["status"])
        XCTAssertEqual(merged, try b.merging(a))
        XCTAssertEqual(merged, try merged.merging(a))
    }
    func testTombstoneNeverResurrectsEvenAgainstNewerOfflineEdit() throws {
        let version = FieldVersion(counter: 2, writer: "A")
        let deleted = ReplicaRecord(key: "trip:x", kind: .trip, deletion: version)
        let offline = ReplicaRecord(key: "trip:x", kind: .trip, fields: ["notes": .string("Old device")], versions: ["notes": .init(counter: 900, writer: "B")])
        XCTAssertNotNil(try deleted.merging(offline).deletion)
        XCTAssertNotNil(try offline.merging(deleted).deletion)
    }
    func testEqualCounterTieBreakIsDeterministicAndMergeIsAssociative() throws {
        func record(_ writer: String, _ text: String) -> ReplicaRecord {
            ReplicaRecord(key: "trip:x", kind: .trip, fields: ["notes": .string(text)], versions: ["notes": .init(counter: 5, writer: writer)])
        }
        let a = record("A", "a"), b = record("B", "b"), c = record("C", "c")
        XCTAssertEqual(try a.merging(b), try b.merging(a))
        XCTAssertEqual(try a.merging(b).merging(c), try a.merging(b.merging(c)))
    }
    func testInvalidVersionOrMismatchedIdentityFailsWithoutGuessing() throws {
        let a = ReplicaRecord(key: "trip:x", kind: .trip, fields: ["notes": .string("x")])
        XCTAssertThrowsError(try a.validated())
        let b = ReplicaRecord(key: "trip:y", kind: .trip)
        XCTAssertThrowsError(try b.merging(ReplicaRecord(key: "trip:z", kind: .trip)))
    }
    func testFavoriteOffDoesNotAppearInSavedDirectory() throws {
        let r = ReplicaRecord(key: "favorite:pines", kind: .favorite, fields: ["campgroundID": .string("pines"), "saved": .bool(false)], versions: ["campgroundID": .init(counter: 1, writer: "A"), "saved": .init(counter: 2, writer: "A")])
        XCTAssertTrue(try RecordProjection.snapshot([r]).favorites.isEmpty)
    }
    func testPartialRigDownloadIsRecoverableRatherThanResettingProfile() throws {
        let f: [String: RecordValue] = ["name": .string("Camper"), "experience": .string("new"), "rigKey": .string("rig:profile")]
        let r = ReplicaRecord(key: "profile:current", kind: .profile, fields: f, versions: f.mapValues { _ in .init(counter: 1, writer: "A") })
        XCTAssertThrowsError(try RecordProjection.snapshot([r]))
    }
    func testConcurrentTemplateGenerationsDoNotUnionTwoSetsOfDefaultSteps() throws {
        let a = ChecklistFactory.templates(for: Rig())
        let b = ChecklistFactory.templates(for: Rig())
        let left = try RecordProjection.documents(LibrarySnapshot(state: AppState(templates: a)))
        let right = try RecordProjection.documents(LibrarySnapshot(state: AppState(templates: b)))
        var all: [String: ReplicaRecord] = [:]
        for (documents, writer) in [(left, "A"), (right, "B")] {
            for (key, value) in documents {
                var document = value
                document.versions = value.fields.mapValues { _ in .init(counter: 1, writer: writer) }
                all[key] = try all[key].map { try $0.merging(document) } ?? document
            }
        }
        let restored = try RecordProjection.snapshot(Array(all.values))
        XCTAssertEqual(restored.state.templates, b)
        XCTAssertEqual(restored.state.templates?.setup.count, b.setup.count)
    }
    func testMissingInitialChecklistMemberRejectsPartialProjection() throws {
        let rig = Rig()
        let trip = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 0), departure: Date(timeIntervalSince1970: 1), rig: rig)
        var documents = try RecordProjection.documents(LibrarySnapshot(state: AppState(trips: [trip])))
        let key = "trip:\(trip.id)"
        documents[key]?.fields["initialChecklistKeys"] = .array([.string("checklistItem:missing")])
        XCTAssertThrowsError(try RecordProjection.snapshot(Array(documents.values)))
    }

}
