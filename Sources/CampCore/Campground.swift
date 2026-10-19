import Foundation

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

    public init(id: String, name: String, region: String, latitude: Double, longitude: Double,
                amenities: [String: Bool] = [:], supportedRigTypes: [RigType]? = nil,
                maximumMotorhomeFeet: Double? = nil, maximumTrailerFeet: Double? = nil,
                nightlyPriceUSD: Double? = nil, notes: String = "", sourceURL: String, checkedAt: String,
                timeZoneIdentifier: String? = nil) {
        self.id = id; self.name = name; self.region = region; self.latitude = latitude; self.longitude = longitude
        self.amenities = amenities; self.supportedRigTypes = supportedRigTypes
        self.maximumMotorhomeFeet = maximumMotorhomeFeet; self.maximumTrailerFeet = maximumTrailerFeet
        self.nightlyPriceUSD = nightlyPriceUSD; self.notes = notes; self.sourceURL = sourceURL; self.checkedAt = checkedAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
    public func availability(of amenity: CampAmenity) -> Bool? { amenities[amenity.rawValue] }
}

public struct CampgroundDirectory: Codable, Sendable {
    public let schemaVersion: Int
    public let coverageNote: String
    public let campgrounds: [Campground]
}

public struct CampgroundFilter: Equatable, Sendable {
    public var query = ""
    public var requiredAmenities: Set<CampAmenity> = []
    public var noElectricHookups = false
    public var rigType: RigType?
    public var minimumRigLengthFeet: Double?
    public var maximumNightlyPriceUSD: Double?
    public init() {}

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
