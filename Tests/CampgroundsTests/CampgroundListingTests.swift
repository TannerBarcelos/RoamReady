import XCTest
import CampCore
@testable import Campgrounds

final class CampgroundListingTests: XCTestCase {
    private func place(_ id: String, latitude: Double = 38, longitude: Double = -120, phone: String? = nil,
                       website: String? = nil) -> CampgroundListing {
        CampgroundListing(mapItemIdentifier: id, name: "Camp \(id)", phone: phone, websiteURL: website,
                          latitude: latitude, longitude: longitude)
    }

    func testAPlaceIsKeyedByItsAppleMapsIdentifier() {
        let listing = place("I6FD7682FD36BB3BE")
        XCTAssertEqual(listing.id, "apple:I6FD7682FD36BB3BE")
        XCTAssertEqual(CampgroundIdentity(listing.id), .appleMaps("I6FD7682FD36BB3BE"))
    }

    func testTheWebsiteOpensOnlyAsAWebPage() {
        XCTAssertEqual(place("a", website: "https://pineflat.example/reserve").websiteLink?.host, "pineflat.example")
        XCTAssertNotNil(place("a", website: "http://older-campground.example").websiteLink, "Many campground sites are still http")
        XCTAssertNil(place("a", website: "javascript:alert(1)").websiteLink)
        XCTAssertNil(place("a", website: "ftp://files.example").websiteLink)
        XCTAssertNil(place("a", website: "https://").websiteLink)
        XCTAssertNil(place("a").websiteLink, "No website, no Website button")
    }

    func testPhoneNumbersDialTheMainLine() {
        XCTAssertEqual(place("a", phone: "+1 (209) 555-0100").phoneLink?.absoluteString, "tel:+12095550100")
        XCTAssertEqual(place("a", phone: "(530) 543-2600 ext. 2").phoneLink?.absoluteString, "tel:5305432600")
        XCTAssertNil(place("a", phone: "123").phoneLink)
        XCTAssertNil(place("a").phoneLink)
    }

    func testResultsMergeWithoutDuplicatesNearestFirst() {
        let near = place("near", latitude: 38.01), far = place("far", latitude: 39), middle = place("middle", latitude: 38.5)
        let merged = [far, near].merged(with: [near, middle], nearLatitude: 38, longitude: -120)
        XCTAssertEqual(merged.map(\.mapItemIdentifier), ["near", "middle", "far"])
        XCTAssertEqual(near.distance(toLatitude: 38, longitude: -120), 1_112, accuracy: 5)
    }

    func testSearchTextIsCleaned() {
        XCTAssertEqual(cleanedSearchText("  Moab, \n UT  "), "Moab, UT")
        XCTAssertNil(cleanedSearchText("   "))
        XCTAssertNil(cleanedSearchText("\u{0007}"))
        XCTAssertEqual(cleanedSearchText(String(repeating: "a", count: 300))?.count, 100)
    }
}
