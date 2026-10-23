import XCTest
@testable import CampCore

final class TripDetailsTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    /// May 1–3 at a Denver campground, planned in Los Angeles.
    private func denverTrip() -> TripDraft {
        TripDraft(campgroundName: "Pines", arrival: date("2026-05-01T07:00:00Z"), departure: date("2026-05-03T07:00:00Z"),
                  campgroundID: "ridb-1", planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/Denver")
    }

    func testInvalidTripDatesNamesAndCoordinatesAreRejected() {
        let arrival = date("2026-05-01T07:00:00Z")
        var trip = TripDraft(campgroundName: "Camp", arrival: arrival, departure: arrival.addingTimeInterval(-1))
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidDates) }
        trip.departure = arrival; trip.campgroundName = "  "
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .missingCampground) }
        trip.campgroundName = "Camp"; trip.latitude = 91; trip.longitude = 0
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidCoordinates) }
        trip.latitude = 40; trip.longitude = nil
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidCoordinates) }
        trip.longitude = -105
        XCTAssertNoThrow(try trip.validate(), "A same-day visit is valid")
    }

    func testBookingValidation() {
        var trip = denverTrip()
        trip.bookingURL = "http://insecure.example"
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingLink) }
        trip.bookingURL = "javascript:alert(1)"
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingLink) }
        trip.bookingURL = "https://www.recreation.gov/account/orders"
        XCTAssertNoThrow(try trip.validate())
        XCTAssertNotNil(trip.bookingLink)
        trip.totalCost = -1
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingAmount) }
        trip.totalCost = .nan
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidBookingAmount) }
        trip.totalCost = 120
        XCTAssertNoThrow(try trip.validate())
    }

    func testBookingFieldsAreOptionalAndBlankTextIsNotStored() {
        var draft = denverTrip()
        XCTAssertFalse(draft.hasBookingDetails)
        draft.siteNumber = " 12 "; draft.confirmationNumber = "   "; draft.loop = "A"; draft.campgroundName = " Pines "
        let cleaned = draft.cleaned
        XCTAssertEqual(cleaned.siteNumber, "12")
        XCTAssertEqual(cleaned.campgroundName, "Pines")
        XCTAssertNil(cleaned.confirmationNumber)
        XCTAssertEqual(cleaned.loop, "A")
        XCTAssertTrue(cleaned.hasBookingDetails)
        XCTAssertEqual(TripDraft(cleaned), cleaned, "Copying a trip's details keeps every field")
    }

    func testCheckInAndOutUseCampgroundLocalTimeAcrossDaylightSavingChange() throws {
        // Planned in Los Angeles for a New York campground; DST ends on 2026-11-01 in both.
        var trip = TripDraft(campgroundName: "DST campground", arrival: date("2026-10-31T07:00:00Z"), departure: date("2026-11-01T07:00:00Z"),
                             planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/New_York")
        trip.checkInMinutes = 15 * 60; trip.checkOutMinutes = 11 * 60
        XCTAssertEqual(trip.checkInDate, date("2026-10-31T19:00:00Z"), "3 PM EDT")
        XCTAssertEqual(trip.checkOutDate, date("2026-11-01T16:00:00Z"), "11 AM EST, after the change")
        XCTAssertNoThrow(try trip.validate())
    }

    func testCheckOutMustBeAfterCheckInOnASameDayStay() {
        var trip = TripDraft(campgroundName: "Day use", arrival: date("2026-05-01T07:00:00Z"), departure: date("2026-05-01T07:00:00Z"),
                             planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/Denver")
        trip.checkInMinutes = 14 * 60; trip.checkOutMinutes = 10 * 60
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidCheckTimes) }
        trip.checkOutMinutes = 18 * 60
        XCTAssertNoThrow(try trip.validate())
        trip.checkInMinutes = 24 * 60
        XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidCheckTimes) }
    }

    func testForecastUsesDestinationCivilDaysRatherThanDeviceInstants() throws {
        let trip = TripDraft(campgroundName: "Eastern campground", arrival: date("2026-05-01T07:00:00Z"), departure: date("2026-05-03T07:00:00Z"),
                             planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/New_York")
        let range = try XCTUnwrap(trip.forecastDayWindow)
        XCTAssertEqual(range.lowerBound, date("2026-05-01T04:00:00Z"))
        XCTAssertEqual(range.upperBound, date("2026-05-03T04:00:00Z"))
        XCTAssertTrue(range.contains(trip.campgroundCalendar.startOfDay(for: date("2026-05-01T05:00:00Z"))))
        XCTAssertFalse(range.contains(trip.campgroundCalendar.startOfDay(for: date("2026-04-30T18:00:00Z"))))
    }

    func testDestinationDayWindowHandlesDaylightSavingChange() throws {
        let trip = TripDraft(campgroundName: "DST campground", arrival: date("2026-11-01T07:00:00Z"), departure: date("2026-11-02T08:00:00Z"),
                             planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/New_York")
        let range = try XCTUnwrap(trip.forecastDayWindow)
        XCTAssertEqual(range.lowerBound, date("2026-11-01T04:00:00Z"))
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 25 * 3600)
    }

    func testATripCompletesOnTheDayAfterDepartureAtTheCampground() {
        let trip = denverTrip()
        XCTAssertFalse(trip.isCompleted(asOf: date("2026-05-03T20:00:00Z")), "Still the departure day in Denver")
        XCTAssertFalse(trip.isCompleted(asOf: date("2026-05-04T05:59:00Z")), "11:59 PM MDT on May 3")
        XCTAssertTrue(trip.isCompleted(asOf: date("2026-05-04T06:00:00Z")), "Midnight MDT on May 4")
    }

    func testMarkingCompleteEarlyIsReversible() {
        var trip = denverTrip()
        let before = date("2026-04-01T00:00:00Z")
        XCTAssertFalse(trip.isCompleted(asOf: before))
        trip.completedAt = before
        XCTAssertTrue(trip.isCompleted(asOf: before))
        XCTAssertFalse(trip.endedByDate(asOf: before))
        trip.completedAt = nil
        XCTAssertFalse(trip.isCompleted(asOf: before))
    }

    func testBeenHereFollowsCompletedTripsUnlessTheOwnerChose() {
        XCTAssertTrue(CampgroundList.beenTo.includes(wantToGo: false, favorite: false, beenTo: nil, hasCompletedTrip: true))
        XCTAssertFalse(CampgroundList.beenTo.includes(wantToGo: false, favorite: false, beenTo: false, hasCompletedTrip: true),
                       "Removing it sticks even though the trip is complete")
        XCTAssertTrue(CampgroundList.beenTo.includes(wantToGo: false, favorite: false, beenTo: true, hasCompletedTrip: false))
        XCTAssertTrue(CampgroundList.wantToGo.includes(wantToGo: true, favorite: false, beenTo: nil, hasCompletedTrip: false))
        XCTAssertFalse(CampgroundList.favorite.includes(wantToGo: true, favorite: false, beenTo: true, hasCompletedTrip: true))
    }
}
