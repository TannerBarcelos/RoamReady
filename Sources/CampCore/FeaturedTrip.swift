import Foundation

public extension Collection where Element: TripDetails {
    /// Home's featured trip: the earliest-arriving trip whose dates include today, or else the
    /// soonest upcoming one. Overlapping current trips resolve to the one that arrived first.
    /// Nil when nothing is current or ahead; completed trips are never featured.
    func featuredTrip(asOf now: Date = Date()) -> Element? {
        filter { $0.isActive(asOf: now) }.min { $0.arrival < $1.arrival }
            ?? filter { $0.daysUntilArrival(asOf: now) != nil }.min { $0.arrival < $1.arrival }
    }
}

public extension Collection where Element: TripDetails & Identifiable {
    /// The trip a side-by-side Home shows: the one the owner picked while it is still in the
    /// library, otherwise the featured trip. Nothing picked follows the featured trip as days pass.
    func displayedTrip(selected id: Element.ID?, asOf now: Date = Date()) -> Element? {
        if let id, let picked = first(where: { $0.id == id }) { return picked }
        return featuredTrip(asOf: now)
    }
}
