import Foundation

/// The lists a saved campground can be on (#30).
public enum CampgroundList: String, CaseIterable, Identifiable, Sendable {
    case wantToGo, beenTo, favorite
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .wantToGo: "Want to go"
        case .beenTo: "Been here"
        case .favorite: "Favorites"
        }
    }
}

/// A campground on the owner's lists. Name and region are kept so the lists work offline,
/// where the online directory isn't available.
public struct SavedCampground: Codable, Equatable, Sendable {
    public var campgroundID: String
    public var name: String
    public var region: String
    public var wantToGo: Bool
    public var favorite: Bool
    /// Nil follows your trips: a completed trip at this campground counts as been here.
    /// True or false is the owner's explicit choice and overrides the trips.
    public var beenTo: Bool?
    public init(campgroundID: String, name: String = "", region: String = "", wantToGo: Bool = false,
                favorite: Bool = false, beenTo: Bool? = nil) {
        self.campgroundID = campgroundID; self.name = name; self.region = region
        self.wantToGo = wantToGo; self.favorite = favorite; self.beenTo = beenTo
    }
    /// Nothing left to remember: on no list and no explicit "been here" choice.
    public var isEmpty: Bool { !wantToGo && !favorite && beenTo == nil }
}

public extension LibrarySnapshot {
    /// Whether the campground is on `list`. "Been here" follows completed trips unless the owner chose.
    func isCampground(_ id: String, on list: CampgroundList, asOf now: Date = Date()) -> Bool {
        let entry = saved[id]
        switch list {
        case .wantToGo: return entry?.wantToGo == true
        case .favorite: return entry?.favorite == true
        case .beenTo:
            if let choice = entry?.beenTo { return choice }
            return state.trips.contains { $0.campgroundID == id && $0.isCompleted(asOf: now) }
        }
    }

    /// Campground IDs on `list`, including ones "been here" through a completed trip.
    func campgroundIDs(on list: CampgroundList, asOf now: Date = Date()) -> [String] {
        let candidates = Set(saved.keys).union(list == .beenTo ? Set(state.trips.compactMap(\.campgroundID)) : [])
        return candidates.filter { isCampground($0, on: list, asOf: now) }.sorted()
    }

    /// Puts a campground on a list or takes it off. Taking it off "Been here" sticks even when
    /// a completed trip would otherwise put it there.
    mutating func setCampground(_ id: String, name: String, region: String, on list: CampgroundList, _ included: Bool) {
        var entry = saved[id] ?? SavedCampground(campgroundID: id)
        if !name.isEmpty { entry.name = name }
        if !region.isEmpty { entry.region = region }
        switch list {
        case .wantToGo: entry.wantToGo = included
        case .favorite: entry.favorite = included
        case .beenTo: entry.beenTo = included
        }
        saved[id] = entry.isEmpty ? nil : entry
    }
}
