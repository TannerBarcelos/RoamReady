import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// The Grocery list against a real SwiftData store, in memory.
@MainActor @Suite(.serialized)
struct GroceryLibraryTests {
    let container: ModelContainer
    let context: ModelContext
    let rig: Rig
    let trip: Trip

    init() throws {
        container = try LibraryStore.inMemory()
        context = container.mainContext
        rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        var draft = TripDraft(campgroundName: "Pines", arrival: arrival, departure: arrival.addingTimeInterval(2 * 86_400))
        draft.planningTimeZoneIdentifier = "America/Denver"
        trip = try Trip.create(draft, rig: rig, in: context)
    }

    @discardableResult
    private func dish(_ name: String, day: Int = 0, kind: MealKind = .dinner, _ items: [DishItemDraft]) throws -> MenuDish {
        let dish = try trip.addDish(MenuDishDraft(name: name), to: .standard(day: day, kind: kind))
        for item in items { try dish.addItem(item) }
        return dish
    }

    private func row(_ name: String) -> GroceryList.Row? { trip.groceryList.rows.first { $0.key == GroceryList.key(for: name) } }

    // MARK: Building the list

    @Test func ingredientsMergeAcrossDishesAndDays() throws {
        try dish("Breakfast burritos", day: 0, kind: .breakfast, [
            DishItemDraft(name: "Eggs", amount: 1, unit: .dozen), DishItemDraft(name: "Tortillas", amount: 8)])
        try dish("Pancakes", day: 1, kind: .breakfast, [
            DishItemDraft(name: " eggs ", amount: 6), DishItemDraft(name: "Flour", amount: 2, unit: .cup)])
        try dish("Steak", day: 2, kind: .dinner, [
            DishItemDraft(name: "Ribeye", amount: 2, unit: .lb), DishItemDraft(name: "Eggs", amount: 1, unit: .dozen)])
        try dish("Steak sandwiches", day: 2, kind: .lunch, [DishItemDraft(name: "RIBEYE", amount: 1, unit: .lb)])

        let list = trip.groceryList
        #expect(list.rows.map(\.name) == ["Eggs", "Flour", "RIBEYE", "Tortillas"], "Lunch comes before dinner, so its spelling is seen first")
        #expect(row("Eggs")?.amountText == "2 dozen, 6")
        #expect(row("Ribeye")?.amountText == "3 lb")
        #expect(row("Ribeye")?.ingredientCount == 2)
        #expect(row("Eggs")?.name == "Eggs", "The first-seen spelling, in menu order")
        #expect(list.progressText == "4 of 4 left")
    }

    @Test func anIngredientWithAnUnknownUnitShowsAsSavedAlongsideTheTotals() throws {
        let steak = try dish("Steak", [DishItemDraft(name: "Cheese", amount: 1, unit: .lb)])
        let odd = try steak.addItem(DishItemDraft(name: "Cheese", amount: 2))
        odd.unitValue = "wheel"
        #expect(odd.amount == nil && odd.amountText == "2 wheel")
        #expect(row("cheese")?.amountText == "1 lb, 2 wheel")
    }

    @Test func mealsOutsideTheTripDatesAreLeftOut() throws {
        try dish("Chili", day: 0, [DishItemDraft(name: "Beans", amount: 2, unit: .can)])
        let late = try trip.addMeal(MealDraft(title: "Late supper"), day: 9)
        let kept = try trip.addDish(MenuDishDraft(name: "Stew"), to: .added(late.persistentModelID))
        try kept.addItem(DishItemDraft(name: "Beans", amount: 4, unit: .can))
        try kept.addItem(DishItemDraft(name: "Carrots"))
        try context.save()

        #expect(trip.mealsOutsideDates.count == 1)
        #expect(trip.groceryList.rows.map(\.name) == ["Beans"])
        #expect(row("Beans")?.amountText == "2 can", "Outside meals add nothing to a row")
        #expect(row("Carrots") == nil)
    }

    @Test func aTripWithoutIngredientsHasAnEmptyList() throws {
        #expect(trip.groceryList.isEmpty)
        try dish("Chili", [])
        #expect(trip.groceryList.isEmpty)
    }

    // MARK: Have and Need

    @Test func checkingARowMarksEveryIngredientBehindItAndANewOneReturnsItToNeed() throws {
        let breakfast = try dish("Burritos", day: 0, kind: .breakfast, [DishItemDraft(name: "Eggs", amount: 6)])
        let pancakes = try dish("Pancakes", day: 1, kind: .breakfast, [DishItemDraft(name: "eggs", amount: 2), DishItemDraft(name: "Flour")])
        let key = GroceryList.key(for: "Eggs")

        trip.setHave(true, forGroceryKey: key)
        #expect(breakfast.sortedItems.map(\.have) == [true])
        #expect(pancakes.sortedItems.map(\.have) == [true, false], "Only the row's own ingredients")
        #expect(row("Eggs")?.isHave == true)
        #expect(trip.groceryList.progressText == "1 of 2 left")

        try pancakes.addItem(DishItemDraft(name: "Eggs", amount: 4))
        #expect(row("Eggs")?.isHave == false, "More are needed now")
        #expect(row("Eggs")?.amountText == "12")
        #expect(trip.groceryList.need.map(\.name) == ["Eggs", "Flour"])

        trip.setHave(true, forGroceryKey: key)
        #expect(row("Eggs")?.isHave == true)
        trip.setHave(false, forGroceryKey: key)
        #expect(trip.groceryList.need.count == 2)
        #expect(breakfast.sortedItems.map(\.have) == [false])
    }

    @Test func aMixedRowReadsAsNeedAndCheckingItMarksEveryIngredientHave() throws {
        let first = try dish("A", day: 0, [DishItemDraft(name: "Butter", amount: 1, unit: .lb)])
        let second = try dish("B", day: 1, [DishItemDraft(name: "butter", amount: 1, unit: .lb)])
        first.sortedItems[0].have = true

        #expect(row("Butter")?.isHave == false)
        #expect(trip.groceryList.have.isEmpty)
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Butter"))
        #expect([first, second].flatMap(\.sortedItems).map(\.have) == [true, true])
        #expect(trip.groceryList.progressText == "All set")
    }

    @Test func settingHaveLeavesIngredientsOutsideTheDatesAlone() throws {
        let late = try trip.addMeal(MealDraft(title: "Late supper"), day: 9)
        let outside = try trip.addDish(MenuDishDraft(name: "Stew"), to: .added(late.persistentModelID)).addItem(DishItemDraft(name: "Beans"))
        let inside = try dish("Chili", [DishItemDraft(name: "Beans")]).sortedItems[0]
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Beans"))
        #expect(inside.have && !outside.have)
    }

    @Test func editingAnIngredientKeepsItsHaveMark() throws {
        let item = try dish("Chili", [DishItemDraft(name: "Beans", amount: 2, unit: .can)]).sortedItems[0]
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Beans"))
        try item.update(DishItemDraft(name: "Black beans", amount: 3, unit: .can))
        #expect(item.have)
        #expect(item.name == "Black beans" && item.amountText == "3 can")
        #expect(row("Black beans")?.isHave == true)
    }

    @Test func aDraftCopyOfAnIngredientStartsAsNeed() throws {
        let dinner = try dish("Chili", [DishItemDraft(name: "Beans", amount: 2, unit: .can)])
        let original = dinner.sortedItems[0]
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Beans"))

        let copy = try trip.addDish(MenuDishDraft(name: "Chili"), to: .standard(day: 1, kind: .dinner)).addItem(original.draft)
        #expect(original.have)
        #expect(!copy.have, "Copies are made from the draft, which has no Have")
        #expect(copy.name == "Beans" && copy.amountText == "2 can")
        #expect(row("Beans")?.isHave == false)
        #expect(DishItemDraft(name: "Beans", amount: 2, unit: .can) == original.draft, "The draft is only name, amount, and unit")
    }

    // MARK: Overrides

    @Test func anOverrideChangesTheRowAndNotTheIngredients() throws {
        let steak = try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")

        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: key)
        try context.save()
        #expect(row("Ribeye")?.amountText == "5 lb")
        #expect(row("Ribeye")?.menuLine == "Menu: 3 lb")
        #expect(steak.sortedItems[0].amountText == "3 lb", "The menu is unchanged")
        #expect(trip.groceryOverrides?.count == 1)
    }

    @Test func anOverrideSurvivesAMenuChange() throws {
        let steak = try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: key)

        try steak.addItem(DishItemDraft(name: "ribeye", amount: 1, unit: .lb))
        #expect(row("Ribeye")?.amountText == "5 lb")
        #expect(row("Ribeye")?.menuLine == "Menu: 4 lb")
        trip.setHave(true, forGroceryKey: key)
        #expect(row("Ribeye")?.amountText == "5 lb", "Checking a row keeps its amount")
    }

    @Test func settingAnOverrideAgainUpdatesTheSameRecord() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: key)
        trip.setGroceryAmount(IngredientAmount(6, unit: .lb), forKey: key)
        #expect(trip.groceryOverrides?.count == 1)
        #expect(row("Ribeye")?.amountText == "6 lb")
        trip.setGroceryAmount(nil, forKey: key)
        #expect(row("Ribeye")?.amountText == "")
        #expect(row("Ribeye")?.menuLine == "Menu: 3 lb")
    }

    @Test func resetReturnsARowToTheMenuTotal() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: key)
        trip.resetGroceryAmount(forKey: key)
        try context.save()
        #expect(row("Ribeye")?.amountText == "3 lb")
        #expect(row("Ribeye")?.override == nil)
        #expect(try context.fetchCount(FetchDescriptor<GroceryAmountOverride>()) == 0)
    }

    @Test func anOverrideForANameNoLongerOnTheMenuIsNotShown() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: key)
        trip.removeMeal(try #require(trip.menuMeal(.standard(day: 0, kind: .dinner))))
        try context.save()
        #expect(trip.groceryList.isEmpty)
        #expect(trip.groceryOverrides?.count == 1, "It is kept in case the ingredient comes back")

        try dish("Steak again", [DishItemDraft(name: "ribeye", amount: 2, unit: .lb)])
        #expect(row("Ribeye")?.amountText == "5 lb")
    }

    @Test func duplicateOverridesFromSyncUseTheNewestAndResetClearsBoth() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")
        func record(_ value: Double, at seconds: TimeInterval) {
            let override = GroceryAmountOverride()
            context.insert(override)
            override.itemKey = key; override.amountValue = value; override.unitValue = "lb"
            override.updatedAt = Date(timeIntervalSince1970: seconds)
            override.trip = trip
        }
        record(8, at: 2_000); record(5, at: 3_000); record(2, at: 1_000)
        try context.save()
        #expect(row("Ribeye")?.amountText == "5 lb", "The newest wins")

        trip.setGroceryAmount(IngredientAmount(6, unit: .lb), forKey: key)
        #expect(row("Ribeye")?.amountText == "6 lb", "Editing keeps the newest record newest")
        #expect(trip.groceryOverrides?.count == 3, "Nothing is deleted to merge them")

        trip.resetGroceryAmount(forKey: key)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<GroceryAmountOverride>()) == 0)
        #expect(row("Ribeye")?.amountText == "3 lb")
    }

    @Test func resetOnlyClearsItsOwnRow() throws {
        try dish("Cookout", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb), DishItemDraft(name: "Eggs", amount: 6)])
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: GroceryList.key(for: "Ribeye"))
        trip.setGroceryAmount(IngredientAmount(12), forKey: GroceryList.key(for: "Eggs"))
        trip.resetGroceryAmount(forKey: GroceryList.key(for: "Ribeye"))
        #expect(row("Eggs")?.amountText == "12")
        #expect(row("Ribeye")?.amountText == "3 lb")
    }

    @Test func anOverrideWithAnUnknownUnitShowsAsSaved() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        let key = GroceryList.key(for: "Ribeye")
        let override = GroceryAmountOverride()
        context.insert(override)
        override.itemKey = key; override.amountValue = 2; override.unitValue = "slab"; override.trip = trip
        #expect(row("Ribeye")?.amountText == "2 slab")
        #expect(row("Ribeye")?.editableAmount == nil)
    }

    // MARK: Deleting

    @Test func deletingATripDeletesItsOverridesButNotAnotherTripsOverrides() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: GroceryList.key(for: "Ribeye"))
        var draft = TripDraft(campgroundName: "Lake", arrival: trip.arrival, departure: trip.departure)
        draft.planningTimeZoneIdentifier = "America/Denver"
        let other = try Trip.create(draft, rig: rig, in: context)
        other.setGroceryAmount(IngredientAmount(2), forKey: "eggs")
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<GroceryAmountOverride>()) == 2)

        context.delete(trip)
        try context.save()
        let remaining = try context.fetch(FetchDescriptor<GroceryAmountOverride>())
        #expect(remaining.map(\.itemKey) == ["eggs"])
        #expect(try context.fetchCount(FetchDescriptor<DishItem>()) == 0)
    }

    @Test func theMenuWipeLeavesOverridesAndHaveMarksAlone() throws {
        let old = TripMeal(day: 1, kind: .lunch)
        context.insert(old)
        old.hasStructuredAmounts = false
        old.trip = trip
        let oldDish = MenuDish(); context.insert(oldDish); oldDish.name = "Old"; oldDish.meal = old
        let oldItem = DishItem(); context.insert(oldItem); oldItem.name = "Beans"; oldItem.dish = oldDish

        let item = try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)]).sortedItems[0]
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Ribeye"))
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: GroceryList.key(for: "Ribeye"))
        try context.save()

        #expect(try MenuWipe.deleteMealsWithoutStructuredAmounts(in: context) == 1)
        #expect(try context.fetchCount(FetchDescriptor<GroceryAmountOverride>()) == 1)
        #expect(item.have)
        #expect(row("Ribeye")?.amountText == "5 lb")
        #expect(row("Beans") == nil)
        #expect(try MenuWipe.deleteMealsWithoutStructuredAmounts(in: context) == 0)
    }

    // MARK: Assistant and export

    @Test func theAssistantMenuResourceCarriesTheGroceryList() throws {
        try dish("Cookout", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb), DishItemDraft(name: "Eggs", amount: 1, unit: .dozen)])
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Eggs"))
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: GroceryList.key(for: "Ribeye"))

        let menu = trip.assistantTools().output(for: CampingToolCall(focus: .menu))
        #expect(menu.contains("Need (1):"))
        #expect(menu.contains("- \"Ribeye\", amount: \"5 lb\" (the owner changed it; the menu adds up to \"3 lb\")"))
        #expect(menu.contains("Have (1):"))
        #expect(menu.contains("- \"Eggs\", amount: \"1 dozen\""))
    }

    @Test func theExportWritesWithHaveMarksAndOverrides() throws {
        try dish("Steak", [DishItemDraft(name: "Ribeye", amount: 3, unit: .lb)])
        trip.setHave(true, forGroceryKey: GroceryList.key(for: "Ribeye"))
        trip.setGroceryAmount(IngredientAmount(5, unit: .lb), forKey: GroceryList.key(for: "Ribeye"))
        try context.save()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appending(path: "Export.zip")
        try LibraryExport.write(from: context, to: archive, workspace: directory.appending(path: "work"))
        #expect((try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
    }
}
