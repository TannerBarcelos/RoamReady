import Foundation

/// The lists a saved campground can be on (#30).
public enum CampgroundList: String, CaseIterable, Identifiable, Sendable {
    case wantToGo, beenTo, favorite
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .wantToGo: "Want to go"
        case .beenTo: "Have been"
        case .favorite: "Favorites"
        }
    }

    /// Whether a campground is on this list. "Have been" follows completed trips at the campground
    /// unless the owner chose explicitly (`beenTo` true or false).
    public func includes(wantToGo: Bool, favorite: Bool, beenTo: Bool?, hasCompletedTrip: Bool) -> Bool {
        switch self {
        case .wantToGo: wantToGo
        case .favorite: favorite
        case .beenTo: beenTo ?? hasCompletedTrip
        }
    }
}
