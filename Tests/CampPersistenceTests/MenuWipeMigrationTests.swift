import Foundation
import SwiftData
import Testing
import CampCore
@testable import CampPersistence

/// The menu entities as they shipped before structured amounts: `TripMeal` has no marker and `DishItem` has
/// only the free-text `quantity`. Trips and the rest of the library aren't part of this snapshot; the
/// lightweight migration creates their (empty) tables, and the wipe's effect on them is covered in
/// `MenuWipeTests`.
private enum PreStructuredAmountsSchema {
    @Model final class TripMeal {
        var dayOffset: Int = 0
        var kindValue: String = "other"
        var title: String = ""
        var position: Int = 0
        var createdAt: Date = Date.now
        @Relationship(deleteRule: .cascade, inverse: \MenuDish.meal) var dishes: [MenuDish]? = []
        init() {}
    }
    @Model final class MenuDish {
        var name: String = ""
        var notes: String = ""
        var position: Int = 0
        var createdAt: Date = Date.now
        var meal: TripMeal?
        @Relationship(deleteRule: .cascade, inverse: \DishItem.dish) var items: [DishItem]? = []
        init() {}
    }
    @Model final class DishItem {
        var name: String = ""
        var quantity: String = ""
        var position: Int = 0
        var dish: MenuDish?
        init() {}
    }
}

/// A real on-disk lightweight migration from the previous schema, to prove the wipe finds old rows.
@MainActor
struct MenuWipeMigrationTests {
    @Test func aLibraryFromTheShippedSchemaReadsOldMealsAsUnmarkedAndWipesThem() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Library.store")
        do {
            let old = try ModelContainer(for: PreStructuredAmountsSchema.TripMeal.self,
                                         configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = old.mainContext
            for (index, name) in ["Old chili", "Old pancakes"].enumerated() {
                let meal = PreStructuredAmountsSchema.TripMeal(); meal.dayOffset = index; meal.kindValue = "dinner"
                context.insert(meal)
                let dish = PreStructuredAmountsSchema.MenuDish(); dish.name = name; dish.meal = meal
                context.insert(dish)
                for ingredient in ["Beans", "Beef"] {
                    let item = PreStructuredAmountsSchema.DishItem(); item.name = ingredient; item.quantity = "2 lb"; item.dish = dish
                    context.insert(item)
                }
            }
            try context.save()
        }

        do {
            let migrated = try LibraryStore.container(at: url, cloudKitContainer: nil)
            let context = migrated.mainContext
            let meals = try context.fetch(FetchDescriptor<TripMeal>())
            #expect(meals.count == 2)
            #expect(meals.allSatisfy { !$0.hasStructuredAmounts }, "Rows from before the marker read as false")
            let items = try context.fetch(FetchDescriptor<DishItem>())
            #expect(items.count == 4)
            #expect(items.allSatisfy { $0.amountValue == nil && $0.unitValue == nil && $0.quantity == "2 lb" })

            // A meal planned after the update carries the marker, so it is kept.
            let rig = try Rig.add(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5), to: context)
            let trip = try Trip.create(TripDraft(campgroundName: "Pines", arrival: Date(timeIntervalSince1970: 1_800_000_000), departure: Date(timeIntervalSince1970: 1_800_086_400)), rig: rig, in: context)
            let dish = try trip.addDish(MenuDishDraft(name: "New chili"), to: .standard(day: 0, kind: .dinner))
            try dish.addItem(DishItemDraft(name: "Beans", amount: 2, unit: .can))
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<TripMeal>()) == 3)

            #expect(MenuWipe.runAtLaunch(in: context) == 2)
            #expect(try context.fetchCount(FetchDescriptor<TripMeal>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<MenuDish>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<DishItem>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Rig>()) == 1)
        }

        let reopened = try LibraryStore.container(at: url, cloudKitContainer: nil)
        #expect(MenuWipe.runAtLaunch(in: reopened.mainContext) == 0)
        let meals = try reopened.mainContext.fetch(FetchDescriptor<TripMeal>())
        #expect(meals.count == 1 && meals[0].hasStructuredAmounts)
        #expect(try reopened.mainContext.fetch(FetchDescriptor<DishItem>()).first?.amountText == "2 can")
    }
}
