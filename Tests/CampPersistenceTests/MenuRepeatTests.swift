import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// Repeating a meal's dishes onto other trip days, against a real SwiftData store, in memory.
@MainActor @Suite(.serialized)
struct MenuRepeatTests {
    let container: ModelContainer
    let context: ModelContext
    let trip: Trip

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
        let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival.addingTimeInterval(3 * 86_400))
        draft.planningTimeZoneIdentifier = "America/Denver"
        trip = try Trip.create(draft, rig: rig, in: context)
    }

    private func breakfast(_ day: Int) -> MenuMeal.ID { .standard(day: day, kind: .breakfast) }

    private func meal(_ id: MenuMeal.ID) throws -> MenuMeal { try #require(trip.menuMeal(id)) }

    private func names(_ id: MenuMeal.ID) -> [String] { trip.menuMeal(id)?.dishes.map(\.name) ?? [] }

    /// One place that builds an ingredient, so a change to the draft's fields touches one line.
    private func ingredient(_ name: String, _ amount: Double? = nil, _ unit: IngredientUnit? = nil) -> DishItemDraft {
        DishItemDraft(name: name, amount: amount, unit: unit)
    }

    @discardableResult
    private func plan(_ name: String, notes: String = "", ingredients: [DishItemDraft] = [], photo: Data? = nil,
                      in id: MenuMeal.ID) throws -> MenuDish {
        let dish = try trip.addDish(MenuDishDraft(name: name, notes: notes), photo: photo, to: id)
        for item in ingredients { try dish.addItem(item) }
        return dish
    }

    @Test func eachDayGetsAnIndependentCopy() throws {
        let pancakes = try plan("Pancakes", notes: "Cast iron", ingredients: [ingredient("Mix", 1, .box)], in: breakfast(0))
        let source = try meal(breakfast(0))

        #expect(try trip.repeatDishes([pancakes], of: source, onDays: [1, 2]) == 2)
        try context.save()
        let first = try #require(trip.menuMeal(breakfast(1))?.dishes.first)
        let second = try #require(trip.menuMeal(breakfast(2))?.dishes.first)
        #expect(first !== pancakes && first !== second)

        try first.update(MenuDishDraft(name: "Waffles", notes: "Iron"), photo: nil)
        try first.sortedItems[0].update(ingredient("Batter", 2))
        try pancakes.addItem(ingredient("Syrup"))
        #expect(second.draft == MenuDishDraft(name: "Pancakes", notes: "Cast iron"))
        #expect(second.sortedItems.map(\.draft) == [ingredient("Mix", 1, .box)])
        #expect(pancakes.sortedItems.map(\.name) == ["Mix", "Syrup"])
        #expect(names(breakfast(0)) == ["Pancakes"])
    }

    @Test func notesAndIngredientOrderAreCopiedButNotThePhoto() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let ingredients = [ingredient("Eggs", 12), ingredient("Bacon", 1, .lb), ingredient("Bread")]
        let dish = try plan("Breakfast burritos", notes: "Wrap in foil", ingredients: ingredients, photo: jpeg, in: breakfast(0))
        try trip.repeatDishes([dish], of: try meal(breakfast(0)), onDays: [1])

        let copy = try #require(trip.menuMeal(breakfast(1))?.dishes.first)
        #expect(copy.draft == MenuDishDraft(name: "Breakfast burritos", notes: "Wrap in foil"))
        #expect(copy.sortedItems.map(\.draft) == ingredients)
        #expect(copy.photoData == nil)
        #expect(dish.photoData == jpeg, "The source keeps its photo")
    }

    @Test func aDayWithTheSameNameIsSkippedWhateverTheCaseOrSpacing() throws {
        let pancakes = try plan("Pancakes", in: breakfast(0))
        let bacon = try plan("Bacon", in: breakfast(0))
        try plan("PANCAKES", in: breakfast(1))
        // Names are trimmed on entry, but one synced from elsewhere may not be.
        try plan("Bacon", in: breakfast(2)).name = "  bacon "

        #expect(try trip.repeatDishes([pancakes, bacon], of: try meal(breakfast(0)), onDays: [1, 2, 3]) == 4)
        #expect(names(breakfast(1)) == ["PANCAKES", "Bacon"])
        #expect(names(breakfast(2)) == ["  bacon ", "Pancakes"])
        #expect(names(breakfast(3)) == ["Pancakes", "Bacon"])
    }

    @Test func repeatingTwiceAddsNothing() throws {
        let dish = try plan("Oatmeal", ingredients: [ingredient("Oats")], in: breakfast(0))
        let source = try meal(breakfast(0))
        #expect(try trip.repeatDishes([dish], of: source, onDays: [1, 2]) == 2)
        #expect(try trip.repeatDishes([dish], of: source, onDays: [1, 2, 3]) == 1, "Only the new day gets one")
        #expect(try trip.repeatDishes([dish], of: source, onDays: [1, 2, 3]) == 0)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<MenuDish>()) == 4)
        #expect(try context.fetchCount(FetchDescriptor<DishItem>()) == 4)
    }

    @Test func aStandardMealThatWasNotStoredIsStoredOnTheTargetDay() throws {
        let dish = try plan("Chili", in: .standard(day: 0, kind: .dinner))
        #expect(trip.storedMeals.count == 1)
        try trip.repeatDishes([dish], of: try meal(.standard(day: 0, kind: .dinner)), onDays: [2])
        try context.save()

        #expect(trip.storedMeals.count == 2)
        let stored = try #require(trip.storedMeals.first { $0.dayOffset == 2 })
        #expect(stored.kind == .dinner)
        #expect(names(.standard(day: 2, kind: .dinner)) == ["Chili"])
        #expect(!trip.storedMeals.contains { $0.dayOffset == 1 }, "Days that weren't chosen stay unstored")
    }

    @Test func addedMealsMatchByTitleAndAreCreatedWhenMissing() throws {
        let source = try trip.addMeal(MealDraft(title: "Second breakfast"), day: 0)
        let sourceID = MenuMeal.ID.added(source.persistentModelID)
        let scones = try plan("Scones", in: sourceID)
        let existing = try trip.addMeal(MealDraft(title: "  second BREAKFAST "), day: 1)
        try trip.addMeal(MealDraft(title: "Campfire dessert"), day: 2)

        #expect(try trip.repeatDishes([scones], of: try meal(sourceID), onDays: [1, 2]) == 2)
        try context.save()

        #expect(names(.added(existing.persistentModelID)) == ["Scones"], "Day 1 reuses its meal with that title")
        #expect(trip.menu(on: 1).filter { !$0.isStandard }.count == 1)
        let created = trip.menu(on: 2).filter { !$0.isStandard }
        #expect(created.map(\.title) == ["Campfire dessert", "Second breakfast"])
        #expect(created[1].dishes.map(\.name) == ["Scones"])
        #expect(created[0].dishes.isEmpty)
        #expect(names(breakfast(1)).isEmpty, "An added meal never lands in a standard one")
    }

    @Test func aRepeatThatCopiesNothingCreatesNoMeal() throws {
        let source = try trip.addMeal(MealDraft(title: "Brunch"), day: 0)
        let sourceID = MenuMeal.ID.added(source.persistentModelID)
        let toast = try plan("Toast", in: sourceID)
        #expect(try trip.repeatDishes([], of: try meal(sourceID), onDays: [1]) == 0)
        #expect(try trip.repeatDishes([toast], of: try meal(sourceID), onDays: []) == 0)
        #expect(try trip.repeatDishes([toast], of: try meal(sourceID), onDays: [0, 99]) == 0, "Its own day and unlisted days are ignored")
        #expect(trip.storedMeals.count == 1)
    }

    @Test func onlyTheSelectedDishesAreCopied() throws {
        let pancakes = try plan("Pancakes", in: breakfast(0))
        try plan("Bacon", in: breakfast(0))
        let eggs = try plan("Eggs", in: breakfast(0))
        try trip.repeatDishes([eggs, pancakes], of: try meal(breakfast(0)), onDays: [1])
        #expect(names(breakfast(1)) == ["Pancakes", "Eggs"], "In the source's order, not the order given")
        #expect(names(breakfast(0)) == ["Pancakes", "Bacon", "Eggs"])
    }

    @Test func copiesGoAfterTheExistingDishesInTheSourceOrder() throws {
        try plan("Yogurt", in: breakfast(1))
        try plan("Fruit", in: breakfast(1))
        let pancakes = try plan("Pancakes", in: breakfast(0))
        let bacon = try plan("Bacon", in: breakfast(0))
        let source = try meal(breakfast(0))
        source.reorderDishes([bacon, pancakes])

        try trip.repeatDishes([pancakes, bacon], of: source, onDays: [1])
        let day = try meal(breakfast(1))
        #expect(day.dishes.map(\.name) == ["Yogurt", "Fruit", "Bacon", "Pancakes"])
        #expect(day.dishes.map(\.position) == [0, 1, 2, 3])
    }

    @Test func aMealOutsideTheTripDatesRepeatsOntoTheTripsDays() throws {
        let late = try plan("Chili", ingredients: [ingredient("Beans")], in: .standard(day: 9, kind: .dinner))
        let outside = try #require(trip.mealsOutsideDates.first)
        #expect(try trip.repeatDishes([late], of: outside, onDays: [0, 9, 4, 61]) == 1)
        #expect(names(.standard(day: 0, kind: .dinner)) == ["Chili"])
        #expect(trip.mealsOutsideDates.count == 1, "Nothing new lands outside the dates")
    }

    @Test func aDishWithoutANameIsNotCopied() throws {
        let record = TripMeal(day: 0, kind: .lunch); context.insert(record); record.trip = trip
        let blank = MenuDish(); context.insert(blank); blank.name = "  "; blank.meal = record
        let soup = try plan("Soup", in: .standard(day: 0, kind: .lunch))
        #expect(try trip.repeatDishes([blank, soup], of: try meal(.standard(day: 0, kind: .lunch)), onDays: [1]) == 1)
        #expect(names(.standard(day: 1, kind: .lunch)) == ["Soup"])
    }
}
