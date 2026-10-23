import XCTest
@testable import CampCore

final class SiteDetailsTests: XCTestCase {
    let arrival = Date(timeIntervalSince1970: 1_800_000_000)
    let trailer = RigDraft(make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5)

    func testSiteDetailsAreKeptWithTheBookingAndEmptyDetailsAreNotStored() {
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival)
        draft.site = SiteDetails()
        XCTAssertNil(draft.cleaned.site)
        XCTAssertFalse(draft.cleaned.hasBookingDetails)

        draft.site = SiteDetails(parking: .backIn, maxLengthFeet: 35, electric: .amp50, sewer: false)
        XCTAssertEqual(draft.cleaned.site, draft.site)
        XCTAssertTrue(draft.cleaned.hasBookingDetails)
        XCTAssertEqual(draft.site?.summary, "Back-in · 35 ft · 50 amp · No sewer")
        XCTAssertEqual(TripDraft(draft).site, draft.site, "Editing a trip starts from its site details")
    }

    func testSiteLengthMustBeAPlausibleNumberOfFeet() {
        var trip = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival)
        for bad in [0, -5, 500, .nan, .infinity] {
            trip.site = SiteDetails(maxLengthFeet: bad)
            XCTAssertThrowsError(try trip.validate()) { XCTAssertEqual($0 as? CampError, .invalidSiteLength) }
        }
        trip.site = SiteDetails(maxLengthFeet: 24)
        XCTAssertNoThrow(try trip.validate())
    }

    func testUnknownLengthNeverReportsTheRigAsTooLong() {
        XCTAssertFalse(SiteDetails().isTooShort(for: trailer))
        XCTAssertFalse(SiteDetails(maxLengthFeet: 18).isTooShort(for: RigDraft(type: .tent, equipment: .none)))
        XCTAssertTrue(SiteDetails(maxLengthFeet: 18).isTooShort(for: trailer))
        XCTAssertFalse(SiteDetails(maxLengthFeet: 19.5).isTooShort(for: trailer))
    }

    func testFirstSiteNotesAreTrimmed() {
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival)
        draft.notes = "  Shady, level pad \n"
        XCTAssertEqual(draft.cleaned.notes, "Shady, level pad")
    }
}
