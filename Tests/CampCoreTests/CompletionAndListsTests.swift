import XCTest
@testable import CampCore

/// #31: completed trips. #30: saved campground lists.
final class CompletionAndListsTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    /// May 1–3 at a Denver campground, planned in Los Angeles.
    private func trip(campgroundID: String? = "ridb-1") -> Trip {
        Trip(campgroundName: "Pines", arrival: date("2026-05-01T07:00:00Z"), departure: date("2026-05-03T07:00:00Z"),
             campgroundID: campgroundID, planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/Denver")
    }

    func testATripCompletesOnTheDayAfterDepartureAtTheCampground() {
        let trip = trip()
        XCTAssertFalse(trip.isCompleted(asOf: date("2026-05-03T20:00:00Z")), "Still the departure day in Denver")
        XCTAssertFalse(trip.isCompleted(asOf: date("2026-05-04T05:59:00Z")), "11:59 PM MDT on May 3")
        XCTAssertTrue(trip.isCompleted(asOf: date("2026-05-04T06:00:00Z")), "Midnight MDT on May 4")
    }

    func testMarkingCompleteEarlyIsStoredAndReversible() throws {
        var trip = trip()
        let before = date("2026-04-01T00:00:00Z")
        XCTAssertFalse(trip.isCompleted(asOf: before))
        trip.completedAt = before
        XCTAssertTrue(trip.isCompleted(asOf: before))
        XCTAssertFalse(trip.endedByDate(asOf: before))
        trip.completedAt = nil
        XCTAssertFalse(trip.isCompleted(asOf: before))
    }

    func testCompletedTripsPutTheirCampgroundOnBeenHereUnlessRemoved() {
        var library = LibrarySnapshot(state: AppState(trips: [trip()]))
        let during = date("2026-05-02T18:00:00Z"), after = date("2026-05-05T18:00:00Z")
        XCTAssertFalse(library.isCampground("ridb-1", on: .beenTo, asOf: during))
        XCTAssertTrue(library.isCampground("ridb-1", on: .beenTo, asOf: after))
        XCTAssertEqual(library.campgroundIDs(on: .beenTo, asOf: after), ["ridb-1"])
        // The owner's removal sticks, even though the trip is still completed.
        library.setCampground("ridb-1", name: "Pines", region: "CO", on: .beenTo, false)
        XCTAssertFalse(library.isCampground("ridb-1", on: .beenTo, asOf: after))
        XCTAssertNotNil(library.saved["ridb-1"], "The explicit choice is remembered")
        library.setCampground("ridb-1", name: "", region: "", on: .beenTo, true)
        XCTAssertTrue(library.isCampground("ridb-1", on: .beenTo, asOf: during), "Added by hand before the trip ends")
        XCTAssertEqual(library.saved["ridb-1"]?.name, "Pines", "Blank names don't erase the saved one")
    }

    func testListsAreIndependentAndAnEmptyEntryIsDropped() {
        var library = LibrarySnapshot()
        library.setCampground("ridb-2", name: "Lakeside", region: "UT", on: .wantToGo, true)
        library.setCampground("ridb-2", name: "Lakeside", region: "UT", on: .favorite, true)
        XCTAssertTrue(library.isCampground("ridb-2", on: .wantToGo))
        XCTAssertTrue(library.isCampground("ridb-2", on: .favorite))
        XCTAssertFalse(library.isCampground("ridb-2", on: .beenTo))
        library.setCampground("ridb-2", name: "", region: "", on: .wantToGo, false)
        library.setCampground("ridb-2", name: "", region: "", on: .favorite, false)
        XCTAssertNil(library.saved["ridb-2"])
    }

    func testListsAndCompletionRoundTripThroughRecords() throws {
        var completed = trip(); completed.completedAt = date("2026-05-02T00:00:00Z")
        var library = LibrarySnapshot(state: AppState(trips: [completed]))
        library.setCampground("ridb-1", name: "Pines", region: "CO", on: .favorite, true)
        library.setCampground("ridb-3", name: "Watchman", region: "UT", on: .beenTo, false)
        let records = Array(try RecordProjection.documents(library).values)
        XCTAssertEqual(try RecordProjection.snapshot(records), library)
    }

    func testBookmarksSavedBeforeListsBecomeWantToGo() throws {
        let legacy = ReplicaRecord(key: "favorite:ridb-9", kind: .favorite, fields: ["campgroundID": .string("ridb-9"), "saved": .bool(true)])
        let library = try RecordProjection.snapshot([legacy])
        XCTAssertEqual(library.saved["ridb-9"], SavedCampground(campgroundID: "ridb-9", wantToGo: true))
        XCTAssertEqual(LibrarySnapshot(favorites: ["ridb-9"]), library)
    }
}
