import XCTest
@testable import CampCore

final class SiteDetailsTests: XCTestCase {
    let arrival = Date(timeIntervalSince1970: 1_800_000_000)
    let trailer = Rig(make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5)

    func testSiteDetailsAreCopiedWithBookingAndEmptyDetailsAreNotStored() throws {
        var draft = Trip(campgroundName: "Pines", arrival: arrival, departure: arrival)
        var trip = try Trip.create(campgroundName: "Pines", arrival: arrival, departure: arrival, rig: trailer)
        draft.site = SiteDetails()
        trip.copyBookingDetails(from: draft)
        XCTAssertNil(trip.site)
        XCTAssertFalse(trip.hasBookingDetails)

        draft.site = SiteDetails(parking: .backIn, maxLengthFeet: 35, electric: .amp50, sewer: false)
        trip.copyBookingDetails(from: draft)
        XCTAssertEqual(trip.site, draft.site)
        XCTAssertTrue(trip.hasBookingDetails)
        XCTAssertEqual(trip.site?.summary, "Back-in · 35 ft · 50 amp · No sewer")
    }

    func testSiteLengthMustBeAPlausibleNumberOfFeet() throws {
        var trip = try Trip.create(campgroundName: "Pines", arrival: arrival, departure: arrival, rig: trailer)
        for bad in [0, -5, 500, .nan, .infinity] {
            trip.site = SiteDetails(maxLengthFeet: bad)
            XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidSiteLength) }
        }
        trip.site = SiteDetails(maxLengthFeet: 24)
        XCTAssertNoThrow(try trip.validate())
    }

    func testUnknownLengthNeverReportsTheRigAsTooLong() {
        XCTAssertFalse(SiteDetails().isTooShort(for: trailer))
        XCTAssertFalse(SiteDetails(maxLengthFeet: 18).isTooShort(for: Rig(type: .tent, equipment: .none)))
        XCTAssertTrue(SiteDetails(maxLengthFeet: 18).isTooShort(for: trailer))
        XCTAssertFalse(SiteDetails(maxLengthFeet: 19.5).isTooShort(for: trailer))
    }

    func testTripsSavedBeforeSiteDetailsStillDecode() throws {
        var trip = try Trip.create(campgroundName: "Pines", arrival: arrival, departure: arrival, rig: trailer)
        trip.site = SiteDetails(parking: .pullThrough)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as? [String: Any])
        object.removeValue(forKey: "site")
        let decoded = try JSONDecoder().decode(Trip.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.site)
        XCTAssertEqual(decoded.id, trip.id)
    }
}
