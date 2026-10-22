import XCTest
@testable import CampCore

final class TripContextTests: XCTestCase {
    func testTripReferencesItsRigInsteadOfCopyingIt() throws {
        let rig = Rig(type: .travelTrailer, make: "First rig", equipment: Equipment(slideOuts: false))
        let trip = try Trip.create(campgroundName: "Camp", arrival: Date(), departure: Date(), rig: rig)
        XCTAssertEqual(trip.rigID, rig.id)
        XCTAssertNotNil(trip.planningTimeZoneIdentifier)
    }

    func testCheckInAndOutUseCampgroundLocalTimeAcrossDaylightSavingChange() throws {
        // Planned in Los Angeles for a New York campground; DST ends on 2026-11-01 in both.
        var trip = Trip(campgroundName: "DST campground", arrival: date("2026-10-31T07:00:00Z"),
                        departure: date("2026-11-01T07:00:00Z"),
                        planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/New_York")
        trip.checkInMinutes = 15 * 60; trip.checkOutMinutes = 11 * 60
        XCTAssertEqual(trip.checkInDate, date("2026-10-31T19:00:00Z"), "3 PM EDT")
        XCTAssertEqual(trip.checkOutDate, date("2026-11-01T16:00:00Z"), "11 AM EST, after the change")
        XCTAssertNoThrow(try trip.validate())
    }

    func testCheckOutMustBeAfterCheckInOnASameDayStay() throws {
        var trip = Trip(campgroundName: "Day use", arrival: date("2026-05-01T07:00:00Z"), departure: date("2026-05-01T07:00:00Z"),
                        planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/Denver")
        trip.checkInMinutes = 14 * 60; trip.checkOutMinutes = 10 * 60
        XCTAssertThrowsError(try trip.validateBooking()) { XCTAssertEqual($0 as? CampError, .invalidCheckTimes) }
        trip.checkOutMinutes = 18 * 60
        XCTAssertNoThrow(try trip.validateBooking())
        // Load-time validation tolerates an order that a sync merge could produce.
        trip.checkOutMinutes = 10 * 60
        XCTAssertNoThrow(try trip.validate())
        trip.checkOutMinutes = 18 * 60
        trip.checkInMinutes = 24 * 60
        XCTAssertThrowsError(try trip.validateBooking()) { XCTAssertEqual($0 as? CampError, .invalidCheckTimes) }
    }

    func testForecastUsesDestinationCivilDaysRatherThanDeviceInstants() throws {
        let trip = Trip(campgroundName: "Eastern campground", arrival: date("2026-05-01T07:00:00Z"),
                        departure: date("2026-05-03T07:00:00Z"),
                        planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/New_York")
        let range = try XCTUnwrap(trip.forecastDayWindow)
        XCTAssertEqual(range.lowerBound, date("2026-05-01T04:00:00Z"))
        XCTAssertEqual(range.upperBound, date("2026-05-03T04:00:00Z"))
        XCTAssertTrue(range.contains(trip.campgroundCalendar.startOfDay(for: date("2026-05-01T05:00:00Z"))))
        XCTAssertFalse(range.contains(trip.campgroundCalendar.startOfDay(for: date("2026-04-30T18:00:00Z"))))
    }

    func testDestinationDayWindowHandlesDaylightSavingChange() throws {
        let trip = Trip(campgroundName: "DST campground", arrival: date("2026-11-01T07:00:00Z"),
                        departure: date("2026-11-02T08:00:00Z"),
                        planningTimeZoneIdentifier: "America/Los_Angeles", campgroundTimeZoneIdentifier: "America/New_York")
        let range = try XCTUnwrap(trip.forecastDayWindow)
        XCTAssertEqual(range.lowerBound, date("2026-11-01T04:00:00Z"))
        XCTAssertEqual(range.upperBound, date("2026-11-02T05:00:00Z"))
        XCTAssertEqual(range.upperBound.timeIntervalSince(range.lowerBound), 25 * 3600)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
}
