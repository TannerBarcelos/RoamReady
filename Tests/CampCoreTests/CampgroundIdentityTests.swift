import XCTest
@testable import CampCore

/// #26: campgrounds are keyed by Apple Maps identifier, or a local identity for ones entered by name.
final class CampgroundIdentityTests: XCTestCase {
    func testIdentitiesRoundTripAndEarlierIDsStayReadable() {
        XCTAssertEqual(CampgroundIdentity("apple:I6FD7682FD36BB3BE"), .appleMaps("I6FD7682FD36BB3BE"))
        XCTAssertEqual(CampgroundIdentity.appleMaps("I6FD7682FD36BB3BE").campgroundID, "apple:I6FD7682FD36BB3BE")
        let local = UUID()
        XCTAssertEqual(CampgroundIdentity("local:\(local.uuidString)"), .local(local))
        XCTAssertEqual(CampgroundIdentity("ridb-232447"), .legacy("ridb-232447"))
        XCTAssertEqual(CampgroundIdentity("apple:"), .legacy("apple:"))
        XCTAssertEqual(CampgroundIdentity("local:not-a-uuid"), .legacy("local:not-a-uuid"))
        XCTAssertTrue(CampgroundIdentity("apple:x").isAppleMapsPlace)
        XCTAssertFalse(CampgroundIdentity("ridb-1").isAppleMapsPlace)
    }

    func testCampgroundsEnteredByNameShareALocalIdentityAcrossTrips() {
        let first = CampgroundIdentity.local(named: "Aunt's Farm", among: [])
        guard case .local = CampgroundIdentity(first) else { return XCTFail("Expected a local identity") }
        let trips: [(campgroundID: String?, campgroundName: String)] = [
            (first, "Aunt's Farm"), ("apple:pine-flat", "Pine Flat"), (nil, "Lake House"),
        ]
        XCTAssertEqual(CampgroundIdentity.local(named: "  aunt's farm ", among: trips), first)
        XCTAssertNotEqual(CampgroundIdentity.local(named: "Lake House", among: trips), first)
        guard case .local = CampgroundIdentity(CampgroundIdentity.local(named: "Pine Flat", among: trips)) else {
            return XCTFail("An Apple Maps identity is never reused for a name typed by hand")
        }
    }

    func testTheListIsCalledHaveBeen() {
        XCTAssertEqual(CampgroundList.beenTo.title, "Have been")
    }
}
