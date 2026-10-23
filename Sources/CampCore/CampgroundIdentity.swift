import Foundation

/// How trips and saved lists refer to a campground (`campgroundID`).
///
/// - `apple:<map item identifier>`: a Camp Finder place from Apple Maps. Apple provides
///   `MKMapItem.Identifier` for apps to store and look up again; the place's details are fetched
///   from Apple Maps when shown rather than copied into the library, so saved lists keep only the ID.
/// - `local:<uuid>`: a campground the owner entered by name. Its name is the owner's own data.
/// - Anything else, such as `ridb-<facility>`: a reference from an earlier directory, kept as is
///   so existing trips and lists stay readable.
public enum CampgroundIdentity: Equatable, Sendable {
    case appleMaps(String)
    case local(UUID)
    case legacy(String)

    public static let appleMapsPrefix = "apple:"
    public static let localPrefix = "local:"

    public init(_ campgroundID: String) {
        if campgroundID.hasPrefix(Self.appleMapsPrefix), !campgroundID.dropFirst(Self.appleMapsPrefix.count).isEmpty {
            self = .appleMaps(String(campgroundID.dropFirst(Self.appleMapsPrefix.count)))
        } else if campgroundID.hasPrefix(Self.localPrefix), let id = UUID(uuidString: String(campgroundID.dropFirst(Self.localPrefix.count))) {
            self = .local(id)
        } else {
            self = .legacy(campgroundID)
        }
    }

    public var campgroundID: String {
        switch self {
        case .appleMaps(let identifier): Self.appleMapsPrefix + identifier
        case .local(let id): Self.localPrefix + id.uuidString
        case .legacy(let value): value
        }
    }

    /// An Apple Maps place: only the ID is stored, and the details come from Apple Maps.
    public var isAppleMapsPlace: Bool {
        if case .appleMaps = self { return true }
        return false
    }

    /// The local identity for a campground entered by name: the one an earlier trip with the same
    /// name already has (`trips` as campground ID and name pairs), so repeat visits group together,
    /// or a new one.
    public static func local(named name: String, among trips: [(campgroundID: String?, campgroundName: String)]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = trips.first { trip in
            guard let id = trip.campgroundID, case .local = CampgroundIdentity(id) else { return false }
            return trip.campgroundName.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        return existing?.campgroundID ?? CampgroundIdentity.local(UUID()).campgroundID
    }
}
