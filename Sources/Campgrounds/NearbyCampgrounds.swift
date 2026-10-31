import Foundation

/// Nearby discovery uses a circular 50-mile search inside a map region spanning its full diameter.
public enum NearbyCampgrounds {
    public static let radiusMeters = 50 * 1_609.344
    public static let mapSpanMeters = radiusMeters * 2

    public static func results(_ listings: [CampgroundListing], latitude: Double, longitude: Double) -> [CampgroundListing] {
        listings.filter { $0.distance(toLatitude: latitude, longitude: longitude) <= radiusMeters }
            .merged(with: [], nearLatitude: latitude, longitude: longitude)
    }
}
