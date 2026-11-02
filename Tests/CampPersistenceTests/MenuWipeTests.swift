import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// Deleting menu data from before structured amounts (docs/adr/0001-structured-ingredient-amounts.md).
@MainActor @Suite(.serialized)
struct MenuWipeTests {
    let container: ModelContainer
    let context: ModelContext
    let trip: Trip

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival.addingTimeInterval(2 * 86_400))
        draft.planningTimeZoneIdentifier = "America/Denver"
        trip = try Trip.create(draft, rig: rig, in: context)
    }

    /// A meal as an older build stored it: no marker, with a dish and two ingredients that only had the retired text.
    @discardableResult
    private func addOldMeal(day: Int = 0, kind: MealKind = .dinner) throws -> TripMeal {
        let meal = TripMeal(day: day, kind: kind)
        context.insert(meal)
        meal.hasStructuredAmounts = false
        meal.trip = trip
        let dish = MenuDish(); context.insert(dish); dish.name = "Old chili"; dish.meal = meal
        for name in ["Beans", "Beef"] {
            let item = DishItem(); context.insert(item); item.name = name; item.quantity = "2 lb"; item.dish = dish
        }
        try context.save()
        return meal
    }

    private func counts() throws -> (meals: Int, dishes: Int, items: Int) {
        (try context.fetchCount(FetchDescriptor<TripMeal>()), try context.fetchCount(FetchDescriptor<MenuDish>()),
         try context.fetchCount(FetchDescriptor<DishItem>()))
    }

    @Test func aMealWithoutTheMarkerIsDeletedWithItsDishesAndIngredients() throws {
        try addOldMeal()
        #expect(try counts() == (1, 1, 2))
        #expect(try MenuWipe.deleteMealsWithoutStructuredAmounts(in: context) == 1)
        #expect(try counts() == (0, 0, 0))
        #expect(trip.storedMeals.isEmpty)
    }

    @Test func mealsMadeByTheAppKeepTheirMarkerAndSurviveRepeatedRuns() throws {
        let dinner = try trip.addDish(MenuDishDraft(name: "Chili"), to: .standard(day: 0, kind: .dinner))
        try dinner.addItem(DishItemDraft(name: "Beans", amount: 2, unit: .can))
        let extra = try trip.addMeal(MealDraft(title: "Late snack"), day: 1)
        try trip.addDish(MenuDishDraft(name: "S'mores"), to: .added(extra.persistentModelID))
        try context.save()
        #expect(trip.storedMeals.allSatisfy { $0.hasStructuredAmounts })
        #expect(try counts() == (2, 2, 1))

        for _ in 0..<3 {
            #expect(try MenuWipe.deleteMealsWithoutStructuredAmounts(in: context) == 0)
            #expect(try counts() == (2, 2, 1))
        }
        #expect(dinner.sortedItems.first?.amountText == "2 can")
    }

    @Test func aRepeatedRunKeepsNewMealsAndRemovesOldOnesThatSyncInLater() throws {
        try trip.addDish(MenuDishDraft(name: "Chili"), to: .standard(day: 0, kind: .dinner))
        try context.save()
        #expect(MenuWipe.runAtLaunch(in: context) == 0)
        try addOldMeal(day: 1, kind: .lunch)
        #expect(try counts().meals == 2)
        #expect(MenuWipe.runAtLaunch(in: context) == 1, "No run-once flag: the next launch cleans what arrived since")
        #expect(trip.storedMeals.map(\.dayOffset) == [0])
        #expect(MenuWipe.runAtLaunch(in: context) == 0)
    }

    @Test func nothingButMealsIsTouched() throws {
        trip.notes = "Level pad, site 14"
        trip.saveNoteRevision()
        let tripSteps = trip.steps(.setup).count + trip.steps(.teardown).count
        let rigSteps = try #require(trip.rig).defaultTemplate.setup.count
        #expect(tripSteps > 0 && rigSteps > 0)
        let saved = SavedCampground(campgroundID: "camp-1"); context.insert(saved); saved.name = "Pines"
        try trip.addDish(MenuDishDraft(name: "Chili"), to: .standard(day: 1, kind: .dinner))
        try addOldMeal()
        try context.save()
        let before = (trips: try context.fetchCount(FetchDescriptor<Trip>()), rigs: try context.fetchCount(FetchDescriptor<Rig>()),
                      steps: try context.fetchCount(FetchDescriptor<ChecklistStep>()),
                      revisions: try context.fetchCount(FetchDescriptor<NoteRevision>()),
                      saved: try context.fetchCount(FetchDescriptor<SavedCampground>()))

        #expect(try MenuWipe.deleteMealsWithoutStructuredAmounts(in: context) == 1)

        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == before.trips)
        #expect(try context.fetchCount(FetchDescriptor<Rig>()) == before.rigs)
        #expect(try context.fetchCount(FetchDescriptor<ChecklistStep>()) == before.steps)
        #expect(try context.fetchCount(FetchDescriptor<NoteRevision>()) == before.revisions)
        #expect(try context.fetchCount(FetchDescriptor<SavedCampground>()) == before.saved)
        #expect(trip.notes == "Level pad, site 14")
        #expect(trip.steps(.setup).count + trip.steps(.teardown).count == tripSteps)
        #expect(try #require(trip.rig).defaultTemplate.setup.count == rigSteps)
        #expect(trip.storedMeals.count == 1 && trip.storedMeals[0].dayOffset == 1, "The new meal stays")
        #expect(try counts() == (1, 1, 0))
    }
}
