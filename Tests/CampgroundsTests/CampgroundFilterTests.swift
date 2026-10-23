import XCTest
import CampCore
@testable import Campgrounds

final class CampgroundFilterTests: XCTestCase {
    func testUnknownAmenityDoesNotBecomeKnownAbsentOrPresent() {
        let unknown = place(amenities: [:])
        let dry = place(amenities: ["electricHookup": false])
        var filter = CampgroundFilter()
        filter.noElectricHookups = true
        XCTAssertFalse(filter.matches(unknown))
        XCTAssertTrue(filter.matches(dry))
        filter.noElectricHookups = false
        filter.requiredAmenities = [.amp30]
        XCTAssertFalse(filter.matches(unknown))
        XCTAssertFalse(filter.matches(dry))
        XCTAssertTrue(filter.matches(place(amenities: ["amp30": true])))
    }

    func testLengthUsesTrailerLimitEvenIfMotorhomeLimitWouldFit() {
        let camp = place(amenities: [:], motorhomeLimit: 35, trailerLimit: 24)
        var filter = CampgroundFilter()
        filter.minimumRigLengthFeet = 30
        filter.rigType = .travelTrailer
        XCTAssertFalse(filter.matches(camp))
        filter.rigType = .motorhome
        XCTAssertTrue(filter.matches(camp))
        filter.rigType = nil
        XCTAssertFalse(filter.matches(camp))
    }

    func testFiltersCombineAndDoNotInventUnknownPrices() {
        var filter = CampgroundFilter()
        filter.query = "PINES california"
        filter.requiredAmenities = [.dumpStation]
        XCTAssertTrue(filter.matches(place(amenities: ["dumpStation": true])))
        filter.requiredAmenities.insert(.showers)
        XCTAssertFalse(filter.matches(place(amenities: ["dumpStation": true])))
        filter.requiredAmenities.remove(.showers)
        filter.maximumNightlyPriceUSD = 50
        XCTAssertFalse(filter.matches(place(amenities: ["dumpStation": true])))
        XCTAssertTrue(filter.matches(place(amenities: ["dumpStation": true], price: 40)))
    }

    private func place(amenities: [String: Bool], motorhomeLimit: Double? = nil,
                       trailerLimit: Double? = nil, price: Double? = nil) -> Campground {
        Campground(id: "example", name: "Upper Pines", region: "California", latitude: 37, longitude: -119,
                   amenities: amenities, supportedRigTypes: [.travelTrailer, .motorhome],
                   maximumMotorhomeFeet: motorhomeLimit, maximumTrailerFeet: trailerLimit,
                   nightlyPriceUSD: price, sourceURL: "https://www.nps.gov/", checkedAt: "2026-10-19")
    }

    func testUseMyRigMatchesTypeAndKnownLength() {
        var filter = CampgroundFilter()
        filter.use(RigDraft(type: .travelTrailer, lengthFeet: 19.5))
        XCTAssertEqual(filter.rigType, .travelTrailer); XCTAssertEqual(filter.minimumRigLengthFeet, 19.5)
        filter.minimumRigLengthFeet = 30
        filter.use(RigDraft(type: .motorhome))
        XCTAssertEqual(filter.rigType, .motorhome); XCTAssertEqual(filter.minimumRigLengthFeet, 30, "An unknown length keeps the typed filter")
        filter.use(RigDraft(type: .tent, lengthFeet: 10))
        XCTAssertEqual(filter.rigType, .tent); XCTAssertNil(filter.minimumRigLengthFeet)
    }
}
