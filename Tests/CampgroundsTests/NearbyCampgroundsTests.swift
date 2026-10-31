import XCTest
@testable import Campgrounds

final class NearbyCampgroundsTests: XCTestCase {
    private func place(_ id: String, northMeters: Double = 0, eastMeters: Double = 0) -> CampgroundListing {
        let degreesPerMeter = 180 / (Double.pi * 6_371_000)
        return CampgroundListing(mapItemIdentifier: id, name: id,
                                 latitude: northMeters * degreesPerMeter, longitude: eastMeters * degreesPerMeter)
    }

    func testNearbyViewShowsTheFullDiameterOfAFiftyMileRadius() {
        XCTAssertEqual(NearbyCampgrounds.radiusMeters, 80_467.2, accuracy: 0.001)
        XCTAssertEqual(NearbyCampgrounds.mapSpanMeters, 160_934.4, accuracy: 0.001)
    }

    func testNearbyResultsExcludeOutsideTheCircleAndKeepUniquePlacesNearestFirst() {
        let radius = NearbyCampgrounds.radiusMeters
        let center = place("center")
        let near = place("near", northMeters: 3_000)
        let edge = place("edge", northMeters: radius - 1)
        let outside = place("outside", northMeters: radius + 1)
        let corner = place("corner", northMeters: radius * 0.9, eastMeters: radius * 0.9)
        let results = NearbyCampgrounds.results([outside, edge, corner, near, center, near], latitude: 0, longitude: 0)
        XCTAssertEqual(results.map(\.mapItemIdentifier), ["center", "near", "edge"])
    }

    func testRadiusUsesTheUsersCoordinateAndWorksAcrossTheDateLine() {
        let near = CampgroundListing(mapItemIdentifier: "near", name: "Across the date line", latitude: 0, longitude: -179.9)
        let far = CampgroundListing(mapItemIdentifier: "far", name: "Farther away", latitude: 0, longitude: -178.5)
        let results = NearbyCampgrounds.results([far, near], latitude: 0, longitude: 179.8)
        XCTAssertEqual(results.map(\.mapItemIdentifier), ["near"])
    }
}
