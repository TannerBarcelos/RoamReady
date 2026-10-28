import Foundation
import Testing
import CampCore

struct FeaturedTripTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()
    var today: Date { calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9))! }

    private func trip(_ name: String, _ start: Int, _ end: Int, completed: Bool = false) -> TripDraft {
        let day = calendar.startOfDay(for: today)
        var draft = TripDraft(campgroundName: name,
                              arrival: calendar.date(byAdding: .day, value: start, to: day)!,
                              departure: calendar.date(byAdding: .day, value: end, to: day)!)
        draft.planningTimeZoneIdentifier = calendar.timeZone.identifier
        draft.campgroundTimeZoneIdentifier = calendar.timeZone.identifier
        if completed { draft.completedAt = today }
        return draft
    }

    @Test func prefersTheCurrentTripOverAnUpcomingOne() {
        let trips = [trip("Lake", 3, 5), trip("Pines", -1, 1)]
        #expect(trips.featuredTrip(asOf: today)?.campgroundName == "Pines")
    }

    @Test func overlappingCurrentTripsFeatureTheEarliestArrival() {
        let trips = [trip("Creek", 0, 2), trip("Pines", -1, 1), trip("Lake", 7, 9)]
        #expect(trips.featuredTrip(asOf: today)?.campgroundName == "Pines")
    }

    @Test func withNothingCurrentTheSoonestUpcomingTripIsFeatured() {
        let trips = [trip("Lake", 7, 9), trip("Past", -7, -5), trip("Ridge", 2, 4)]
        #expect(trips.featuredTrip(asOf: today)?.campgroundName == "Ridge")
    }

    @Test func departureDayStillCountsAsCurrent() {
        #expect([trip("Pines", -2, 0)].featuredTrip(asOf: today)?.campgroundName == "Pines")
    }

    @Test func completedAndPastTripsAreNeverFeatured() {
        let trips = [trip("Past", -7, -5), trip("Done early", -1, 1, completed: true)]
        #expect(trips.featuredTrip(asOf: today) == nil)
        #expect([TripDraft]().featuredTrip(asOf: today) == nil)
    }

    @Test func aPickedTripIsShownUntilItLeavesTheLibrary() {
        let trips = [trip("Pines", -1, 1), trip("Lake", 7, 9)]
        #expect(trips.displayedTrip(selected: nil, asOf: today)?.campgroundName == "Pines")
        #expect(trips.displayedTrip(selected: "Lake", asOf: today)?.campgroundName == "Lake")
        #expect(trips.displayedTrip(selected: "Deleted", asOf: today)?.campgroundName == "Pines")
        #expect([TripDraft]().displayedTrip(selected: "Lake", asOf: today) == nil)
    }
}

/// Stands in for a stored trip's identity.
extension TripDraft: Identifiable {
    public var id: String { campgroundName }
}
