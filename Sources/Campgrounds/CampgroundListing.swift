import Foundation
import CampCore

/// What Apple Maps calls the place.
public enum CampgroundKind: String, Codable, Sendable {
    case campground, rvPark
    public var title: String {
        switch self {
        case .campground: "Campground"
        case .rvPark: "RV park"
        }
    }
}

/// A Camp Finder result: a campground or RV park from Apple Maps, as the app shows it.
/// Only what Apple Maps supplies; nothing about prices, hookups, accessibility, rig limits, or
/// availability is inferred. Built from an `MKMapItem` in the app; kept for the session only.
public struct CampgroundListing: Identifiable, Hashable, Sendable {
    /// Apple's `MKMapItem.Identifier`, which Apple allows apps to store and look up again.
    public let mapItemIdentifier: String
    public let name: String
    public let kind: CampgroundKind?
    public let phone: String?
    /// The business's own website, as Apple Maps lists it. This is where people book.
    public let websiteURL: String?
    public let address: String?
    public let latitude: Double
    public let longitude: Double
    /// The campground's time zone, which Apple Maps supplies with the place.
    public let timeZoneIdentifier: String?

    public init(mapItemIdentifier: String, name: String, kind: CampgroundKind? = nil, phone: String? = nil,
                websiteURL: String? = nil, address: String? = nil, latitude: Double, longitude: Double,
                timeZoneIdentifier: String? = nil) {
        self.mapItemIdentifier = mapItemIdentifier; self.name = name; self.kind = kind; self.phone = phone
        self.websiteURL = websiteURL; self.address = address; self.latitude = latitude; self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// The key trips and saved lists use: `apple:<identifier>`.
    public var id: String { CampgroundIdentity.appleMaps(mapItemIdentifier).campgroundID }

    /// Opens in Safari. `http` is allowed because many campground sites still use it.
    public var websiteLink: URL? {
        guard let websiteURL, let url = URL(string: websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// A dialable `tel:` URL, or nil when the number has too few digits to call.
    public var phoneLink: URL? {
        guard let phone else { return nil }
        // Drop extensions ("x2", "ext. 2") so the main line is dialed.
        let main = phone.lowercased().components(separatedBy: CharacterSet(charactersIn: "x")).first ?? phone
        let digits = main.filter { $0.isASCII && $0.isNumber }
        guard (7...15).contains(digits.count) else { return nil }
        return URL(string: "tel:" + (main.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits)
    }

    /// Great-circle distance in meters.
    public func distance(toLatitude otherLatitude: Double, longitude otherLongitude: Double) -> Double {
        let radians = Double.pi / 180
        let dLatitude = (otherLatitude - latitude) * radians, dLongitude = (otherLongitude - longitude) * radians
        let a = sin(dLatitude / 2) * sin(dLatitude / 2)
            + cos(latitude * radians) * cos(otherLatitude * radians) * sin(dLongitude / 2) * sin(dLongitude / 2)
        return 6_371_000 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

public extension Array where Element == CampgroundListing {
    /// Results from several searches as one list: each place once, nearest to the center first.
    func merged(with other: [CampgroundListing], nearLatitude latitude: Double, longitude: Double) -> [CampgroundListing] {
        var seen = Set<String>()
        return (self + other)
            .filter { seen.insert($0.mapItemIdentifier).inserted }
            .sorted { $0.distance(toLatitude: latitude, longitude: longitude) < $1.distance(toLatitude: latitude, longitude: longitude) }
    }
}

/// Text the person typed, made safe to search with: whitespace collapsed, control characters
/// removed, and length bounded. Nil when nothing is left.
public func cleanedSearchText(_ text: String, limit: Int = 100) -> String? {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let safe = String(collapsed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
    return safe.isEmpty ? nil : String(safe.prefix(limit))
}
