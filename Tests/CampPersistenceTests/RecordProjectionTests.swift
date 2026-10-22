import XCTest
import CampCore
@testable import CampPersistence

final class RecordProjectionTests: XCTestCase {
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
        let original = LibrarySnapshot(state: AppState(profile: CamperProfile(name: "Camper"), rigs: [rig, old], trips: [b, a], rigDefaults: [defaults]), saved: ["ridb-1": SavedCampground(campgroundID: "ridb-1", name: "Pines", wantToGo: true)])
        let records = Array(try RecordProjection.documents(original).values)
        XCTAssertEqual(try RecordProjection.snapshot(records.reversed()), original)
    }
    func testFavoriteOffDoesNotAppearInSavedDirectory() throws {
        let r = StoredRecord(key: "favorite:pines", kind: .favorite, fields: ["campgroundID": .string("pines"), "saved": .bool(false)])
        XCTAssertTrue(try RecordProjection.snapshot([r]).saved.isEmpty)
    }
    func testConcurrentDefaultGenerationsDoNotUnionTwoSetsOfDefaultSteps() throws {
        let rig = Rig()
        var a = ChecklistFactory.templates(for: rig); a.rigID = rig.id
        var b = ChecklistFactory.templates(for: rig); b.rigID = rig.id
        let left = try RecordProjection.documents(LibrarySnapshot(state: AppState(rigs: [rig], rigDefaults: [a])))
        let right = try RecordProjection.documents(LibrarySnapshot(state: AppState(rigs: [rig], rigDefaults: [b])))
        var all: [String: StoredRecord] = [:]
        // The managed layer selects the logical singleton winner; here the later device's rows win.
        for documents in [left, right] { all.merge(documents) { _, new in new } }
        let restored = try RecordProjection.snapshot(Array(all.values))
        XCTAssertEqual(restored.state.rigDefaults, [b])
        XCTAssertEqual(restored.state.defaults(for: rig.id)?.setup.count, b.setup.count)
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

    func testListsAndCompletionRoundTripThroughRecords() throws {
        var completed = try Trip.create(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 0), departure: Date(timeIntervalSince1970: 1), rig: Rig())
        completed.campgroundID = "ridb-1"; completed.completedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        var library = LibrarySnapshot(state: AppState(trips: [completed]))
        library.setCampground("ridb-1", name: "Pines", region: "CO", on: .favorite, true)
        library.setCampground("ridb-3", name: "Watchman", region: "UT", on: .beenTo, false)
        let records = Array(try RecordProjection.documents(library).values)
        XCTAssertEqual(try RecordProjection.snapshot(records), library)
    }
}
