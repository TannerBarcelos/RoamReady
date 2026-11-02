import Foundation

/// The lists a saved campground can be on (#30).
public enum CampgroundList: String, CaseIterable, Identifiable, Sendable {
    case wantToGo, beenTo, favorite, wouldNotGo, wouldNotReturn
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .wantToGo: "Want to go"
        case .beenTo: "Have been"
        case .favorite: "Favorites"
        case .wouldNotGo: "Would not go"
        case .wouldNotReturn: "Would not return"
        }
    }

    /// Whether a campground is on this list. "Have been" follows completed trips at the campground
    /// unless the owner chose explicitly (`beenTo` true or false).
    ///
    /// The two avoid lists are worked out here, so a place is on at most one: an avoided place is on
    /// "Would not return" when it counts as been to (explicitly or through a completed trip), and
    /// otherwise on "Would not go". That keeps a completed trip at a "Would not go" place honest
    /// without rewriting the saved entry.
    public func includes(wantToGo: Bool, favorite: Bool, wouldNotGo: Bool = false, wouldNotReturn: Bool = false,
                         beenTo: Bool?, hasCompletedTrip: Bool) -> Bool {
        let been = beenTo ?? hasCompletedTrip
        let avoided = wouldNotGo || wouldNotReturn
        switch self {
        case .wantToGo: return wantToGo
        case .favorite: return favorite
        case .beenTo: return been
        case .wouldNotGo: return avoided && !been
        case .wouldNotReturn: return avoided && been
        }
    }
}
