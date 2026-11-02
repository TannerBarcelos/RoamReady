import Foundation
import SwiftData
import CampCore

/// The owner's campground lists, read from the saved entries and the trips. "Have been" also
/// follows completed trips unless the owner chose otherwise.
public struct CampgroundLists {
    public let saved: [SavedCampground]
    public let trips: [Trip]
    public let now: Date
    public init(saved: [SavedCampground], trips: [Trip], now: Date = .now) {
        self.saved = saved; self.trips = trips; self.now = now
    }

    /// Sync can produce two entries for one campground; the first one decides.
    public func entry(_ campgroundID: String) -> SavedCampground? { saved.first { $0.campgroundID == campgroundID } }

    public func contains(_ campgroundID: String, on list: CampgroundList) -> Bool {
        let entry = entry(campgroundID)
        return list.includes(wantToGo: entry?.wantToGo ?? false, favorite: entry?.favorite ?? false,
                             wouldNotGo: entry?.wouldNotGo ?? false, wouldNotReturn: entry?.wouldNotReturn ?? false, beenTo: entry?.beenTo,
                             hasCompletedTrip: trips.contains { $0.campgroundID == campgroundID && $0.isCompleted(asOf: now) })
    }

    /// Campground IDs on `list`, including ones "have been" through a completed trip.
    public func campgroundIDs(on list: CampgroundList) -> [String] {
        let candidates = Set(saved.map(\.campgroundID)).union(list == .beenTo ? Set(trips.compactMap(\.campgroundID)) : [])
        return candidates.filter { contains($0, on: list) }.sorted()
    }

    /// Completed trips entered by name only, so there is no campground to save.
    public var otherPlaces: [String] {
        Array(Set(trips.filter { $0.campgroundID == nil && $0.isCompleted(asOf: now) }.map(\.campgroundName))).sorted()
    }

    /// Distinct campgrounds on any list, plus the places camped by name only.
    public var count: Int { Set(CampgroundList.allCases.flatMap(campgroundIDs(on:))).count + otherPlaces.count }

    /// The saved name, or the name of a trip there. Nil for an Apple Maps place with no trip yet:
    /// its name comes from Apple Maps, never from the library.
    public func name(_ campgroundID: String) -> String? {
        if let name = entry(campgroundID)?.name, !name.isEmpty { return name }
        return trips.first { $0.campgroundID == campgroundID }?.campgroundName
    }
}

public extension SavedCampground {
    /// Puts a campground on a list or takes it off. Taking it off "Have been" sticks even when a
    /// completed trip would otherwise put it there. An entry left on no list is deleted.
    ///
    /// The avoid lists contradict the others: adding to either one takes the place off "Want to go"
    /// and "Favorites", and adding to those takes it off both. "Would not return" also marks the place
    /// as been to; a place already been to explicitly goes on "Would not return" when "Would not go"
    /// is asked for. (A place been to only through a completed trip is sorted out when the lists are
    /// read.) Taking a place off either avoid list clears both marks, and choosing "Have been" as
    /// false takes it off "Would not return". An Apple
    /// Maps place keeps only its ID: its name and region are never stored.
    static func set(_ campgroundID: String, name: String, region: String, on list: CampgroundList, _ included: Bool,
                    in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<SavedCampground>(predicate: #Predicate { $0.campgroundID == campgroundID })).first
        let entry = existing ?? SavedCampground(campgroundID: campgroundID)
        if existing == nil { context.insert(entry) }
        if CampgroundIdentity(campgroundID).isAppleMapsPlace {
            entry.name = ""; entry.region = ""
        } else {
            if !name.isEmpty { entry.name = name }
            if !region.isEmpty { entry.region = region }
        }
        switch list {
        case .wantToGo:
            entry.wantToGo = included
            if included { entry.wouldNotGo = false; entry.wouldNotReturn = false }
        case .favorite:
            entry.favorite = included
            if included { entry.wouldNotGo = false; entry.wouldNotReturn = false }
        case .beenTo:
            entry.beenTo = included
            if !included { entry.wouldNotReturn = false }
        case .wouldNotGo, .wouldNotReturn:
            entry.wouldNotGo = false; entry.wouldNotReturn = false
            if included {
                entry.wantToGo = false; entry.favorite = false
                if list == .wouldNotReturn { entry.beenTo = true }
                if list == .wouldNotReturn || entry.beenTo == true { entry.wouldNotReturn = true } else { entry.wouldNotGo = true }
            }
        }
        if !entry.wantToGo && !entry.favorite && entry.beenTo == nil && !entry.wouldNotGo && !entry.wouldNotReturn { context.delete(entry) }
    }
}
