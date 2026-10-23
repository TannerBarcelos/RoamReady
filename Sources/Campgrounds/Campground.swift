import Foundation
import CampCore

public enum CampAmenity: String, Codable, CaseIterable, Identifiable, Sendable {
    case electricHookup, amp30, amp50, waterHookup, sewerHookup, dumpStation
    case showers, pets, accessibleSites, pullThrough
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .electricHookup: "Electric hookups"
        case .amp30: "30 amp"
        case .amp50: "50 amp"
        case .waterHookup: "Water at site"
        case .sewerHookup: "Sewer at site"
        case .dumpStation: "Dump station"
        case .showers: "Showers"
        case .pets: "Pets allowed"
        case .accessibleSites: "Accessible sites"
        case .pullThrough: "Pull-through sites"
        }
    }
}

public struct Campground: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let region: String
    public let latitude: Double
    public let longitude: Double
    /// Missing keys mean unknown, never false. A campground amenity may exist at only some sites.
    public let amenities: [String: Bool]
    public let supportedRigTypes: [RigType]?
    public let maximumMotorhomeFeet: Double?
    public let maximumTrailerFeet: Double?
    public let nightlyPriceUSD: Double?
    public let notes: String
    public let sourceURL: String
    public let checkedAt: String
    public let timeZoneIdentifier: String?
    /// Contact details as the source publishes them (schema 2). Older snapshots omit them.
    public let phone: String?
    public let email: String?
    public let reservationURL: String?
    public let websiteURL: String?

    public init(id: String, name: String, region: String, latitude: Double, longitude: Double,
                amenities: [String: Bool] = [:], supportedRigTypes: [RigType]? = nil,
                maximumMotorhomeFeet: Double? = nil, maximumTrailerFeet: Double? = nil,
                nightlyPriceUSD: Double? = nil, notes: String = "", sourceURL: String, checkedAt: String,
                timeZoneIdentifier: String? = nil, phone: String? = nil, email: String? = nil,
                reservationURL: String? = nil, websiteURL: String? = nil) {
        self.id = id; self.name = name; self.region = region; self.latitude = latitude; self.longitude = longitude
        self.amenities = amenities; self.supportedRigTypes = supportedRigTypes
        self.maximumMotorhomeFeet = maximumMotorhomeFeet; self.maximumTrailerFeet = maximumTrailerFeet
        self.nightlyPriceUSD = nightlyPriceUSD; self.notes = notes; self.sourceURL = sourceURL; self.checkedAt = checkedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.phone = phone; self.email = email; self.reservationURL = reservationURL; self.websiteURL = websiteURL
    }
    public func availability(of amenity: CampAmenity) -> Bool? { amenities[amenity.rawValue] }

    /// Where to reserve: the published reservation page, falling back to the source page. `https` only.
    public var reserveLink: URL? { Self.httpsURL(reservationURL) ?? Self.httpsURL(sourceURL) }
    public var websiteLink: URL? { Self.httpsURL(websiteURL) }
    public var sourceLink: URL? { Self.httpsURL(sourceURL) }
    /// A dialable `tel:` URL, or nil when the published number has too few digits to call.
    public var phoneLink: URL? {
        guard let phone else { return nil }
        // Drop extensions ("x2", "ext. 2") so the main line is dialed.
        let main = phone.lowercased().components(separatedBy: CharacterSet(charactersIn: "x")).first ?? phone
        let digits = main.filter { $0.isASCII && $0.isNumber }
        guard (7...15).contains(digits.count) else { return nil }
        return URL(string: "tel:" + (main.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits)
    }
    public var emailLink: URL? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), Self.isPlausibleEmail(email) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"; components.path = email
        return components.url
    }

    static func httpsURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
    static func isPlausibleEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !value.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," }) else { return false }
        return true
    }
}

public struct CampgroundDirectory: Codable, Sendable {
    /// 1: facts only. 2: adds optional contact fields; every schema-1 field is unchanged.
    public static let supportedSchemaVersions = 1...2
    public let schemaVersion: Int
    public let coverageNote: String
    public let campgrounds: [Campground]

    public static func decode(_ data: Data) throws -> CampgroundDirectory {
        let result = try JSONDecoder().decode(CampgroundDirectory.self, from: data)
        guard supportedSchemaVersions.contains(result.schemaVersion) else { throw CampError.unsupportedSchema(result.schemaVersion) }
        return result
    }
}

public struct CampgroundFilter: Equatable, Sendable {
    public var query = ""
    public var requiredAmenities: Set<CampAmenity> = []
    public var noElectricHookups = false
    public var rigType: RigType?
    public var minimumRigLengthFeet: Double?
    public var maximumNightlyPriceUSD: Double?
    public init() {}

    /// "Use my rig": match the rig type and, for RVs with a known length, the site length.
    public mutating func use(_ rig: some RigDetails) {
        rigType = rig.type
        if !rig.type.isRV { minimumRigLengthFeet = nil }
        else if let length = rig.lengthFeet { minimumRigLengthFeet = length }
    }

    public func matches(_ campground: Campground) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let searchable = campground.name + " " + campground.region
        guard terms.allSatisfy({ searchable.localizedCaseInsensitiveContains(String($0)) }) else { return false }
        guard requiredAmenities.allSatisfy({ campground.availability(of: $0) == true }) else { return false }
        if noElectricHookups && campground.availability(of: .electricHookup) != false { return false }
        if let rigType, campground.supportedRigTypes?.contains(rigType) != true { return false }
        if let length = minimumRigLengthFeet, length > 0 {
            // Trailer and motorhome limits cannot be substituted for one another.
            guard let rigType else { return false }
            let limit = rigType.isTowable ? campground.maximumTrailerFeet : campground.maximumMotorhomeFeet
            guard let limit, limit >= length else { return false }
        }
        if let maximum = maximumNightlyPriceUSD {
            guard let price = campground.nightlyPriceUSD, price <= maximum else { return false }
        }
        return true
    }
}
