import Foundation
import Testing
import CampCore

struct MenuTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar
    }()

    private func trip(from start: DateComponents, nights: Int) -> TripDraft {
        let arrival = calendar.date(from: start)!
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival,
                              departure: calendar.date(byAdding: .day, value: nights, to: arrival)!)
        draft.planningTimeZoneIdentifier = calendar.timeZone.identifier
        return draft
    }

    @Test func menuDaysRunFromArrivalThroughDepartureDay() {
        let days = trip(from: DateComponents(year: 2026, month: 7, day: 10, hour: 14), nights: 2).menuDays
        #expect(days.map(\.offset) == [0, 1, 2])
        #expect(days.map(\.number) == [1, 2, 3])
        #expect(days.map { calendar.component(.day, from: $0.date) } == [10, 11, 12])
        #expect(days.allSatisfy { calendar.startOfDay(for: $0.date) == $0.date })
    }

    @Test func aSameDayTripHasOneDay() {
        #expect(trip(from: DateComponents(year: 2026, month: 7, day: 10, hour: 8), nights: 0).menuDays.count == 1)
    }

    @Test func daylightSavingChangeKeepsEachCivilDay() {
        // Denver springs forward on March 8, 2026.
        let days = trip(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12), nights: 2).menuDays
        #expect(days.map { calendar.component(.day, from: $0.date) } == [7, 8, 9])
    }

    @Test func daysFollowThePlanningTimeZoneNotTheDevice() {
        var draft = trip(from: DateComponents(year: 2026, month: 7, day: 10, hour: 23), nights: 1)
        draft.campgroundTimeZoneIdentifier = "America/New_York"
        #expect(draft.menuDays.map { calendar.component(.day, from: $0.date) } == [10, 11])
    }

    @Test func invalidDatesHaveNoMenuDays() {
        var draft = trip(from: DateComponents(year: 2026, month: 7, day: 10), nights: 2)
        draft.departure = calendar.date(byAdding: .day, value: -1, to: draft.arrival)!
        #expect(draft.menuDays.isEmpty)
        #expect(!draft.menuIsTruncated)
    }

    @Test func longTripsAreCapped() {
        let draft = trip(from: DateComponents(year: 2026, month: 1, day: 1), nights: 400)
        #expect(draft.menuDays.count == MenuPolicy.maxDays)
        #expect(draft.menuIsTruncated)
        #expect(!trip(from: DateComponents(year: 2026, month: 1, day: 1), nights: MenuPolicy.maxDays - 1).menuIsTruncated)
    }

    @Test func dayTitlesNumberTheDay() {
        let draft = trip(from: DateComponents(year: 2026, month: 7, day: 10), nights: 1)
        #expect(draft.menuTitle(for: draft.menuDays[1]).hasPrefix("Day 2 · "))
    }

    @Test func draftsTrimAndRequireNames() throws {
        #expect(MenuDishDraft(name: "  Foil packs \n", notes: " Prep at home ").cleaned == MenuDishDraft(name: "Foil packs", notes: "Prep at home"))
        #expect(throws: CampError.missingDishName) { try MenuDishDraft(name: "   ").validate() }
        #expect(DishItemDraft(name: " Ribeye ", quantity: " 2 lb ").cleaned == DishItemDraft(name: "Ribeye", quantity: "2 lb"))
        #expect(throws: CampError.missingItemName) { try DishItemDraft(name: "", quantity: "2").validate() }
        #expect(throws: CampError.missingMealName) { try MealDraft(title: " ").validate() }
        try MealDraft(title: "Second breakfast").validate()
    }

    @Test func summaryInvitesCreatingAMenuUntilADishIsPlanned() {
        #expect(MenuSummary(dishCount: 0, plannedMeals: 0).title == "Create menu")
        #expect(MenuSummary(dishCount: 0, plannedMeals: 0).detail == nil)
        #expect(MenuSummary(dishCount: 1, plannedMeals: 1).detail == "1 dish · 1 meal")
        #expect(MenuSummary(dishCount: 5, plannedMeals: 3).title == "Menu")
        #expect(MenuSummary(dishCount: 5, plannedMeals: 3).detail == "5 dishes · 3 meals")
    }

    @Test func everyDayHasTheFourStandardMeals() {
        #expect(MealKind.standard == [.breakfast, .lunch, .dinner, .snack])
        #expect(MealKind.standard.allSatisfy { $0.isStandard })
        #expect(!MealKind.other.isStandard)
    }
}
