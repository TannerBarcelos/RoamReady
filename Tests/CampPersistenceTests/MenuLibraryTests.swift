import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// Trip menu rules against a real SwiftData store, in memory.
@MainActor @Suite(.serialized)
struct MenuLibraryTests {
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

    private func titles(_ day: Int) -> [String] { trip.menu(on: day).map(\.title) }

    @Test func everyDayListsTheStandardMealsBeforeAnythingIsStored() throws {
        #expect(trip.menuDays.count == 3)
        #expect(titles(0) == ["Breakfast", "Lunch", "Dinner", "Snacks"])
        #expect(trip.storedMeals.isEmpty)
        #expect(trip.menuSummary.isEmpty)
    }

    @Test func theFirstDishStoresItsStandardMeal() throws {
        let dish = try trip.addDish(MenuDishDraft(name: " Steak with brussels sprouts ", notes: "Sear hot"), to: .standard(day: 1, kind: .dinner))
        try context.save()
        #expect(dish.name == "Steak with brussels sprouts")
        #expect(trip.storedMeals.count == 1)
        #expect(trip.menuMeal(.standard(day: 1, kind: .dinner))?.dishes.map(\.name) == ["Steak with brussels sprouts"])
        try trip.addDish(MenuDishDraft(name: "Sourdough"), to: .standard(day: 1, kind: .dinner))
        #expect(trip.storedMeals.count == 1, "Later dishes join the stored meal")
        #expect(trip.menuMeal(.standard(day: 1, kind: .dinner))?.dishes.map(\.name) == ["Steak with brussels sprouts", "Sourdough"])
        #expect(trip.menuSummary == MenuSummary(dishCount: 2, plannedMeals: 1))
        #expect(throws: CampError.missingDishName) { try trip.addDish(MenuDishDraft(name: " "), to: .standard(day: 0, kind: .lunch)) }
    }

    @Test func standardMealsStoredOnTwoDevicesShowAsOne() throws {
        let older = TripMeal(day: 0, kind: .breakfast); context.insert(older); older.trip = trip
        older.createdAt = Date(timeIntervalSince1970: 1)
        let newer = TripMeal(day: 0, kind: .breakfast); context.insert(newer); newer.trip = trip
        let synced = MenuDish(); context.insert(synced); synced.name = "Pancakes"; synced.meal = newer
        try context.save()

        #expect(titles(0) == ["Breakfast", "Lunch", "Dinner", "Snacks"], "No duplicate rows")
        let added = try trip.addDish(MenuDishDraft(name: "Bacon"), to: .standard(day: 0, kind: .breakfast))
        #expect(added.meal === older, "New dishes join the oldest record")
        #expect(trip.menuMeal(.standard(day: 0, kind: .breakfast))?.dishes.map(\.name) == ["Pancakes", "Bacon"])
        #expect(trip.menuSummary == MenuSummary(dishCount: 2, plannedMeals: 1))

        trip.removeMeal(try #require(trip.menuMeal(.standard(day: 0, kind: .breakfast))))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<MenuDish>()) == 0, "Clearing removes both records' dishes")
    }

    @Test func addedMealsFollowTheStandardOnesInTheirOrder() throws {
        let second = try trip.addMeal(MealDraft(title: " Second breakfast "), day: 0)
        try trip.addMeal(MealDraft(title: "Campfire dessert"), day: 0)
        #expect(titles(0) == ["Breakfast", "Lunch", "Dinner", "Snacks", "Second breakfast", "Campfire dessert"])
        #expect(titles(1).count == 4)
        try second.rename(MealDraft(title: "Elevenses"))
        #expect(titles(0)[4] == "Elevenses")
        #expect(throws: CampError.missingMealName) { try trip.addMeal(MealDraft(title: ""), day: 0) }

        let id = MenuMeal.ID.added(second.persistentModelID)
        try trip.addDish(MenuDishDraft(name: "Scones"), to: id)
        trip.removeMeal(try #require(trip.menuMeal(id)))
        try context.save()
        #expect(trip.menuMeal(id) == nil)
        #expect(try context.fetchCount(FetchDescriptor<MenuDish>()) == 0)
        #expect(throws: CampError.mealUnavailable) { try trip.addDish(MenuDishDraft(name: "Tea"), to: id) }
    }

    @Test func aMealFromANewerAppVersionIsKeptAsAnAddedMeal() throws {
        let brunch = TripMeal(day: 0); context.insert(brunch); brunch.trip = trip
        brunch.kindValue = "brunch"
        #expect(brunch.kind == .other)
        #expect(titles(0).last == "Meal")
        #expect(brunch.kindValue == "brunch", "Reading it doesn't rewrite it")
    }

    @Test func shorteningATripKeepsMealsOutsideItsDates() throws {
        try trip.addDish(MenuDishDraft(name: "Chili"), to: .standard(day: 2, kind: .dinner))
        try trip.addMeal(MealDraft(title: "Late snack"), day: 2)
        var shorter = TripDraft(trip); shorter.departure = shorter.arrival
        try trip.update(shorter, rig: trip.rig)
        #expect(trip.menuDays.count == 1)
        let outside = trip.mealsOutsideDates
        #expect(outside.map(\.title) == ["Dinner", "Late snack"])
        #expect(outside.allSatisfy { $0.day == 2 })

        let dinner = try #require(outside.first)
        trip.moveMeal(dinner, toDay: 0)
        #expect(trip.menuMeal(.standard(day: 0, kind: .dinner))?.dishes.map(\.name) == ["Chili"])
        #expect(trip.mealsOutsideDates.map(\.title) == ["Late snack"])
    }

    @Test func dishItemsAreAddedEditedReorderedAndRemoved() throws {
        let dish = try trip.addDish(MenuDishDraft(name: "Foil packs"), to: .standard(day: 0, kind: .dinner))
        let potatoes = try dish.addItem(DishItemDraft(name: " Potatoes ", quantity: " 4 "))
        let sausage = try dish.addItem(DishItemDraft(name: "Sausage", quantity: "1 lb"))
        let onion = try dish.addItem(DishItemDraft(name: "Onion"))
        #expect(potatoes.name == "Potatoes" && potatoes.quantity == "4")
        #expect(dish.sortedItems.map(\.name) == ["Potatoes", "Sausage", "Onion"])
        #expect(throws: CampError.missingItemName) { try dish.addItem(DishItemDraft(name: "  ")) }

        dish.reorderItems([onion, potatoes, sausage])
        #expect(dish.sortedItems.map(\.name) == ["Onion", "Potatoes", "Sausage"])
        try sausage.update(DishItemDraft(name: "Kielbasa", quantity: "2"))
        dish.removeItems([onion])
        try context.save()
        #expect(dish.sortedItems.map(\.draft) == [DishItemDraft(name: "Potatoes", quantity: "4"), DishItemDraft(name: "Kielbasa", quantity: "2")])
    }

    @Test func editingADishKeepsAnUnchangedPhoto() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let dish = try trip.addDish(MenuDishDraft(name: "Pancakes"), photo: jpeg, to: .standard(day: 0, kind: .breakfast))
        try dish.update(MenuDishDraft(name: "Blueberry pancakes", notes: "Bring syrup"), photo: jpeg)
        #expect(dish.draft == MenuDishDraft(name: "Blueberry pancakes", notes: "Bring syrup"))
        #expect(dish.photoData == jpeg)
        try dish.update(dish.draft, photo: nil)
        #expect(dish.photoData == nil)
        #expect(throws: CampError.missingDishName) { try dish.update(MenuDishDraft(name: ""), photo: nil) }

        let entity = try #require(LibraryStore.schema.entities.first { $0.name == "MenuDish" })
        let attribute = try #require(entity.attributesByName["protectedPhoto"])
        #expect(attribute.options.contains(.externalStorage) && attribute.options.contains(.allowsCloudEncryption))
    }

    @Test func dishesReorderWithinTheirMeal() throws {
        let id = MenuMeal.ID.standard(day: 0, kind: .lunch)
        try trip.addDish(MenuDishDraft(name: "Sandwiches"), to: id)
        try trip.addDish(MenuDishDraft(name: "Chips"), to: id)
        let meal = try #require(trip.menuMeal(id))
        meal.reorderDishes(meal.dishes.reversed())
        #expect(trip.menuMeal(id)?.dishes.map(\.name) == ["Chips", "Sandwiches"])
        meal.removeDishes([meal.dishes[0]])
        #expect(trip.menuMeal(id)?.dishes.count == 1)
    }

    @Test func deletingATripDeletesItsMenu() throws {
        let dish = try trip.addDish(MenuDishDraft(name: "Chili"), to: .standard(day: 0, kind: .dinner))
        try dish.addItem(DishItemDraft(name: "Beans"))
        try trip.addMeal(MealDraft(title: "Dessert"), day: 1)
        try context.save()
        context.delete(trip)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<TripMeal>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<MenuDish>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DishItem>()) == 0)
    }
}
