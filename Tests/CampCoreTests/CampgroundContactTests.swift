import XCTest
@testable import CampCore

final class CampgroundContactTests: XCTestCase {
    private let schema1 = Data(#"""
    {"schemaVersion":1,"coverageNote":"note","campgrounds":[{"id":"ridb-1","name":"Pines","region":"CA","latitude":37,
    "longitude":-119,"amenities":{},"notes":"","sourceURL":"https://www.recreation.gov/camping/campgrounds/1","checkedAt":"2026-10-19"}]}
    """#.utf8)

    private let schema2 = Data(#"""
    {"schemaVersion":2,"coverageNote":"note","campgrounds":[{"id":"ridb-1","name":"Pines","region":"CA","latitude":37,
    "longitude":-119,"amenities":{},"notes":"","sourceURL":"https://www.recreation.gov/camping/campgrounds/1","checkedAt":"2026-10-19",
    "phone":"(530) 543-2600 ext 2","email":"pines@example.gov","reservationURL":"https://reserve.example.gov/pines",
    "websiteURL":"https://www.fs.usda.gov/pines"}]}
    """#.utf8)

    func testSchema1SnapshotsStillDecodeWithoutContactDetails() throws {
        let campground = try XCTUnwrap(CampgroundDirectory.decode(schema1).campgrounds.first)
        XCTAssertNil(campground.phone)
        XCTAssertNil(campground.phoneLink)
        XCTAssertNil(campground.emailLink)
        XCTAssertNil(campground.websiteLink)
        XCTAssertEqual(campground.reserveLink?.absoluteString, "https://www.recreation.gov/camping/campgrounds/1",
                       "Reserving falls back to the source page")
    }

    func testSchema2SnapshotsExposeContactActions() throws {
        let campground = try XCTUnwrap(CampgroundDirectory.decode(schema2).campgrounds.first)
        XCTAssertEqual(campground.reserveLink?.absoluteString, "https://reserve.example.gov/pines")
        XCTAssertEqual(campground.websiteLink?.absoluteString, "https://www.fs.usda.gov/pines")
        XCTAssertEqual(campground.phoneLink?.absoluteString, "tel:5305432600")
        XCTAssertEqual(campground.emailLink?.absoluteString, "mailto:pines@example.gov")
    }

    func testUnknownSchemaIsRejected() {
        let future = Data(#"{"schemaVersion":3,"coverageNote":"","campgrounds":[]}"#.utf8)
        XCTAssertThrowsError(try CampgroundDirectory.decode(future)) { error in
            XCTAssertEqual(error as? CampError, .unsupportedSchema(3))
        }
    }

    func testNonHTTPSLinksAndMalformedContactsAreHidden() {
        let campground = Campground(id: "x", name: "X", region: "", latitude: 0, longitude: 0,
                                    sourceURL: "http://insecure.example", checkedAt: "2026-10-19",
                                    phone: "TBD", email: "not an email",
                                    reservationURL: "javascript:alert(1)", websiteURL: "ftp://example.com")
        XCTAssertNil(campground.reserveLink)
        XCTAssertNil(campground.sourceLink)
        XCTAssertNil(campground.websiteLink)
        XCTAssertNil(campground.phoneLink)
        XCTAssertNil(campground.emailLink)
    }

    func testInternationalNumbersKeepTheirPlusSign() {
        let campground = Campground(id: "x", name: "X", region: "", latitude: 0, longitude: 0,
                                    sourceURL: "https://example.com", checkedAt: "2026-10-19", phone: "+1 801 555 0100")
        XCTAssertEqual(campground.phoneLink?.absoluteString, "tel:+18015550100")
    }
}
