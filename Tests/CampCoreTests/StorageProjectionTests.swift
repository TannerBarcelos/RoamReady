import XCTest
@testable import CampCore

final class StorageProjectionTests: XCTestCase {
    func testProjectionRoundTripPreservesTripItemAndPhotoOrdering() throws {
        let rig = Rig(make: "Airstream", model: "Classic", year: 2025, lengthFeet: 30.5, slideCount: 1, axleCount: 2, hasBunkhouse: false)
        var a = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_000), departure: Date(timeIntervalSince1970: 2_000), rig: rig)
        a.photos = [TripPhoto(filename: "b.jpg", caption: "First"), TripPhoto(filename: "a.jpg", caption: "Second")]
        a.loop = "B"; a.confirmationNumber = "0123-4567"; a.bookingProvider = "Recreation.gov"
        a.bookingURL = "https://www.recreation.gov/account/orders"; a.checkInMinutes = 900; a.checkOutMinutes = 1000
        a.totalCost = 84.5; a.amountPaid = 20; a.cancellationDeadline = Date(timeIntervalSinceReferenceDate: 12_345.5)
        let b = try Trip.create(campgroundName: "Watchman", arrival: a.arrival, departure: a.departure, rig: rig)
        var old = rig; old.id = UUID(); old.make = "Previous"; old.archivedAt = Date(timeIntervalSinceReferenceDate: 99)
        var defaults = ChecklistFactory.templates(for: rig); defaults.rigID = rig.id
        let original = LibrarySnapshot(state: AppState(profile: CamperProfile(name: "Camper"), rigs: [rig, old], trips: [b, a], rigDefaults: [defaults]), favorites: ["ridb-1"])
        let records = try RecordProjection.documents(original).values.map { record in
            var r = record; r.versions = r.fields.mapValues { _ in FieldVersion(counter: 1, writer: "A") }; return r
        }
        XCTAssertEqual(try RecordProjection.snapshot(records.reversed()), original)
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
    func testConcurrentDefaultGenerationsDoNotUnionTwoSetsOfDefaultSteps() throws {
        let rig = Rig()
        var a = ChecklistFactory.templates(for: rig); a.rigID = rig.id
        var b = ChecklistFactory.templates(for: rig); b.rigID = rig.id
        let left = try RecordProjection.documents(LibrarySnapshot(state: AppState(rigs: [rig], rigDefaults: [a])))
        let right = try RecordProjection.documents(LibrarySnapshot(state: AppState(rigs: [rig], rigDefaults: [b])))
        var all: [String: ReplicaRecord] = [:]
        for (documents, writer) in [(left, "A"), (right, "B")] {
            for (key, value) in documents {
                var document = value
                document.versions = value.fields.mapValues { _ in .init(counter: 1, writer: writer) }
                all[key] = document // The managed layer selects the logical singleton winner.
            }
        }
        let restored = try RecordProjection.snapshot(Array(all.values))
        XCTAssertEqual(restored.state.rigDefaults, [b])
        XCTAssertEqual(restored.state.defaults(for: rig.id)?.setup.count, b.setup.count)
    }
    func testLegacyRecordsMigrateToRigsDefaultsAndReferences() throws {
        let rig = Rig(make: "Jayco", model: "Eagle", year: 2025, lengthFeet: 38)
        var edited = rig; edited.lengthFeet = 40
        let templates = ChecklistFactory.templates(for: rig)
        var records: [ReplicaRecord] = [
            ReplicaRecord(key: "profile:current", kind: .profile, fields: ["name": .string("Sam"), "experience": .string("new"), "rigKey": .string("rig:profile")]),
            ReplicaRecord(key: "rig:profile", kind: .rig, fields: try RecordProjection.fields(edited)),
            ReplicaRecord(key: "templates:current", kind: .templates, fields: ["id": .string(templates.id.uuidString), "version": .number(1), "sourceURL": .string(templates.sourceURL)])
        ]
        var owned = templates; owned.rigID = rig.id
        records += try RecordProjection.documents(LibrarySnapshot(state: AppState(rigs: [rig], rigDefaults: [owned]))).values.filter { $0.kind == .checklistItem }
        // Two trips: one with the rig as it is now, two sharing the older details.
        var trips: [Trip] = []
        for (index, copy) in [edited, rig, rig].enumerated() {
            let trip = Trip(campgroundName: "Trip \(index)", arrival: Date(timeIntervalSinceReferenceDate: Double(index)), departure: Date(timeIntervalSinceReferenceDate: Double(index)))
            trips.append(trip)
            var fields = try XCTUnwrap(RecordProjection.documents(LibrarySnapshot(state: AppState(trips: [trip])))["trip:\(trip.id)"]?.fields)
            fields["rigKey"] = .string("rig:\(trip.id)"); fields["position"] = .number(Double(index))
            records.append(ReplicaRecord(key: "trip:\(trip.id)", kind: .trip, fields: fields))
            records.append(ReplicaRecord(key: "rig:\(trip.id)", kind: .rig, fields: try RecordProjection.fields(copy)))
        }
        XCTAssertFalse(RecordProjection.legacyRigLayoutKeys(records).isEmpty)
        let state = try RecordProjection.snapshot(records).state
        XCTAssertEqual(state.activeRigs, [edited])
        XCTAssertEqual(state.rigDefaults, [owned])
        XCTAssertEqual(state.trips[0].rigID, edited.id)
        let archived = try XCTUnwrap(state.rig(for: state.trips[1]))
        XCTAssertTrue(archived.isArchived); XCTAssertEqual(archived.lengthFeet, 38)
        XCTAssertEqual(state.trips[2].rigID, archived.id, "Identical copies share one archived rig")
        XCTAssertEqual(state.rigs.count, 2)
        // Deterministic: a second device migrating the same records writes the same records.
        XCTAssertEqual(try RecordProjection.documents(LibrarySnapshot(state: state)),
                       try RecordProjection.documents(RecordProjection.snapshot(records.reversed())))
        // The current layout has no legacy records left.
        XCTAssertTrue(RecordProjection.legacyRigLayoutKeys(Array(try RecordProjection.documents(LibrarySnapshot(state: state)).values)).isEmpty)
    }
    func testMissingRigShowsAsUnavailableRatherThanFailing() throws {
        let trip = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 0), departure: Date(timeIntervalSince1970: 1), rig: Rig())
        let records = Array(try RecordProjection.documents(LibrarySnapshot(state: AppState(trips: [trip]))).values)
        let state = try RecordProjection.snapshot(records).state
        XCTAssertNotNil(state.trips.first?.rigID)
        XCTAssertNil(state.rig(for: state.trips[0]))
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
