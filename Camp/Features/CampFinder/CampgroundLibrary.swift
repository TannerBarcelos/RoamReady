import Foundation
import CampCore
import Campgrounds
import MapKit

enum CampgroundLibrary {
    static let directory: CampgroundDirectory? = {
        guard let url = Bundle.main.url(forResource: "campgrounds", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? CampgroundDirectory.decode(data)
    }()
    static var all: [Campground] { directory?.campgrounds ?? [] }
    static var notice: String { directory?.coverageNote ?? "The campground directory couldn’t be loaded. You can still plan a destination by entering its name." }
}

extension Campground {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var availableAmenities: [CampAmenity] { CampAmenity.allCases.filter { availability(of: $0) == true } }
}
