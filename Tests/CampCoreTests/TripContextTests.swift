import XCTest
@testable import CampCore

final class TripContextTests: XCTestCase {
    func testRigIsACreationSnapshot() throws {
        var rig = Rig(type: .travelTrailer, make: "First rig", equipment: Equipment(slideOuts: false))
        let trip = try Trip.create(campgroundName: "Camp", arrival: Date(), departure: Date(), rig: rig)
        rig.make = "Replacement rig"
        rig.equipment.slideOuts = true
        XCTAssertEqual(trip.rigSnapshot?.make, "First rig")
        XCTAssertEqual(trip.rigSnapshot?.equipment.slideOuts, false)
        XCTAssertNotNil(trip.planningTimeZoneIdentifier)
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
