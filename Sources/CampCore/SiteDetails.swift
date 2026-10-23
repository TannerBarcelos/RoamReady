import Foundation

/// How a rig gets onto the site.
public enum SiteParking: String, Codable, CaseIterable, Identifiable, Sendable {
    case backIn, pullThrough, walkIn
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .backIn: "Back-in"
        case .pullThrough: "Pull-through"
        case .walkIn: "Walk-in"
        }
    }
}

/// The electric service at the site's pedestal.
public enum SiteElectric: String, Codable, CaseIterable, Identifiable, Sendable {
    case noService, amp20, amp30, amp50
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .noService: "None"
        case .amp20: "20 amp"
        case .amp30: "30 amp"
        case .amp50: "50 amp"
        }
    }
}

/// What the owner knows about the site they booked, copied from their reservation or seen on arrival.
/// Campground listings don't publish site-level details, so these are always owner-entered.
/// Every field is optional: nil means "not entered", never "no".
public struct SiteDetails: Codable, Equatable, Sendable {
    public var parking: SiteParking?
    /// The site's maximum equipment length, in feet.
    public var maxLengthFeet: Double?
    public var electric: SiteElectric?
    public var water: Bool?
    public var sewer: Bool?

    public static let lengthRange = 1.0...200.0

    public init(parking: SiteParking? = nil, maxLengthFeet: Double? = nil, electric: SiteElectric? = nil,
                water: Bool? = nil, sewer: Bool? = nil) {
        self.parking = parking; self.maxLengthFeet = maxLengthFeet; self.electric = electric
        self.water = water; self.sewer = sewer
    }

    public var isEmpty: Bool { self == SiteDetails() }

    /// True when the site's length limit is known and shorter than the rig.
    public func isTooShort(for rig: some RigDetails) -> Bool {
        guard let maxLengthFeet, let rigLength = rig.lengthFeet else { return false }
        return rigLength > maxLengthFeet
    }

    /// Short owner-entered facts, e.g. "Pull-through · 40 ft · 30 amp · Water · Sewer".
    public var summary: String {
        var parts: [String] = []
        if let parking { parts.append(parking.title) }
        if let maxLengthFeet { parts.append(String(format: "%g ft", maxLengthFeet)) }
        if let electric { parts.append(electric == .noService ? "No electric" : electric.title) }
        if let water { parts.append(water ? "Water" : "No water") }
        if let sewer { parts.append(sewer ? "Sewer" : "No sewer") }
        return parts.joined(separator: " · ")
    }

    public func validate() throws {
        if let maxLengthFeet {
            guard maxLengthFeet.isFinite, Self.lengthRange.contains(maxLengthFeet) else { throw CampError.invalidSiteLength }
        }
    }
}
