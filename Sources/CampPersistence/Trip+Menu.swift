import Foundation
import SwiftData
import CampCore

/// A meal as the menu shows it. A standard meal may not be stored yet, or may have been stored on two
/// devices before they synced; either way it is one meal here, and nothing is deleted to merge it.
public struct MenuMeal: Identifiable {
    public enum ID: Hashable {
        case standard(day: Int, kind: MealKind)
        case added(PersistentIdentifier)
    }
    public let id: ID
    public let day: Int
    public let kind: MealKind
    /// Oldest first. Empty for a standard meal with nothing planned yet.
    public let records: [TripMeal]

    init(standard kind: MealKind, day: Int, records: [TripMeal]) {
        id = .standard(day: day, kind: kind); self.day = day; self.kind = kind
        self.records = records.filter { $0.kind == kind }.sorted { $0.createdAt < $1.createdAt }
    }

    init(added meal: TripMeal) {
        id = .added(meal.persistentModelID); day = meal.dayOffset; kind = meal.kind; records = [meal]
    }

    public var isStandard: Bool { if case .standard = id { true } else { false } }
    public var title: String {
        guard !isStandard else { return kind.title }
        let title = records.first?.title ?? ""
        return title.isEmpty ? MealKind.other.title : title
    }
    /// The dishes of every record, in the owner's order.
    public var dishes: [MenuDish] {
        records.flatMap(\.sortedDishes).sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    /// Stores the order the list now has, e.g. after a drag.
    public func reorderDishes(_ ordered: [MenuDish]) {
        for (position, dish) in ordered.enumerated() where dish.position != position { dish.position = position }
    }

    public func removeDishes(_ removed: [MenuDish]) {
        for dish in removed { dish.modelContext?.delete(dish) }
    }
}

/// Menu rules: a trip's menu is its days, each with the standard meals plus any the owner adds.
public extension Trip {
    /// Every stored meal, including ones whose day is no longer within the trip's dates.
    var storedMeals: [TripMeal] { (meals ?? []).filter { !$0.isDeleted } }

    /// The day's standard meals, always listed, then the meals the owner added, in their order.
    func menu(on day: Int) -> [MenuMeal] {
        let records = storedMeals.filter { $0.dayOffset == day }
        return MealKind.standard.map { MenuMeal(standard: $0, day: day, records: records) } + Self.addedMeals(records)
    }

    /// Meals planned for days that are no longer part of the trip, e.g. after it was shortened.
    /// They are kept so the owner can move or remove them.
    var mealsOutsideDates: [MenuMeal] {
        let days = Set(menuDays.map(\.offset))
        let records = storedMeals.filter { !days.contains($0.dayOffset) }
        return Set(records.map(\.dayOffset)).sorted().flatMap { day in
            let onDay = records.filter { $0.dayOffset == day }
            return MealKind.standard.map { MenuMeal(standard: $0, day: day, records: onDay) }
                .filter { !$0.records.isEmpty } + Self.addedMeals(onDay)
        }
    }

    /// The meal now, or nil once an added meal has been removed.
    func menuMeal(_ id: MenuMeal.ID) -> MenuMeal? {
        switch id {
        case .standard(let day, let kind):
            MenuMeal(standard: kind, day: day, records: storedMeals.filter { $0.dayOffset == day })
        case .added(let identifier):
            storedMeals.first { $0.persistentModelID == identifier }.map(MenuMeal.init(added:))
        }
    }

    var menuSummary: MenuSummary {
        let planned = storedMeals.filter { !$0.sortedDishes.isEmpty }
        let meals = Set(planned.map { $0.kind.isStandard ? MenuMeal.ID.standard(day: $0.dayOffset, kind: $0.kind) : .added($0.persistentModelID) })
        return MenuSummary(dishCount: planned.reduce(0) { $0 + $1.sortedDishes.count }, plannedMeals: meals.count)
    }

    /// The menu as the Assistant sees it: days with planned dishes, then meals outside the trip's dates.
    var menuFacts: TripMenuFacts {
        let planned = menuDays.map { day in
            TripMenuFacts.Day(label: TripMenuFacts.label(for: day, of: self), meals: Self.facts(menu(on: day.offset)))
        }
        let outside = mealsOutsideDates
        let kept = Set(outside.map(\.day)).sorted().map { day in
            TripMenuFacts.Day(label: TripMenuFacts.outsideLabel(dayNumber: day + 1), meals: Self.facts(outside.filter { $0.day == day }))
        }
        return TripMenuFacts(days: planned + kept)
    }

    /// Adds a dish after the meal's others. A standard meal's first dish stores the meal; with
    /// duplicates from sync, the dish joins the oldest.
    @discardableResult
    func addDish(_ draft: MenuDishDraft, photo: Data? = nil, to id: MenuMeal.ID) throws -> MenuDish {
        let details = draft.cleaned
        try details.validate()
        guard let modelContext, let meal = menuMeal(id) else { throw CampError.mealUnavailable }
        let record: TripMeal
        if let oldest = meal.records.first {
            record = oldest
        } else {
            record = TripMeal(day: meal.day, kind: meal.kind)
            modelContext.insert(record)
            record.trip = self
        }
        let dish = MenuDish()
        modelContext.insert(dish)
        dish.name = details.name
        dish.notes = details.notes
        dish.protectedPhoto = photo
        dish.position = (meal.dishes.last?.position ?? -1) + 1
        dish.meal = record
        return dish
    }

    /// Adds a named meal after the day's other added meals.
    @discardableResult
    func addMeal(_ draft: MealDraft, day: Int) throws -> TripMeal {
        let details = draft.cleaned
        try details.validate()
        guard let modelContext else { throw CampError.mealUnavailable }
        let meal = TripMeal(day: day, kind: .other)
        modelContext.insert(meal)
        meal.title = details.title
        meal.position = (Self.addedMeals(storedMeals.filter { $0.dayOffset == day }).last?.records.first?.position ?? -1) + 1
        meal.trip = self
        return meal
    }

    /// Removes an added meal, or clears a standard one; its dishes and their items go with it.
    func removeMeal(_ meal: MenuMeal) {
        for record in meal.records { modelContext?.delete(record) }
    }

    /// Moves a meal and its dishes to another day. A standard meal joins that day's meal of the same kind.
    func moveMeal(_ meal: MenuMeal, toDay day: Int) {
        for record in meal.records where record.dayOffset != day { record.dayOffset = day }
    }

    private static func facts(_ meals: [MenuMeal]) -> [TripMenuFacts.Meal] {
        meals.compactMap { meal in
            let dishes = meal.dishes.map { dish in
                TripMenuFacts.Dish(name: dish.name, notes: dish.notes,
                                   items: dish.sortedItems.map { TripMenuFacts.Item(name: $0.name, quantity: $0.quantity) })
            }
            return dishes.isEmpty ? nil : TripMenuFacts.Meal(title: meal.title, dishes: dishes)
        }
    }

    private static func addedMeals(_ records: [TripMeal]) -> [MenuMeal] {
        records.filter { !$0.kind.isStandard }
            .sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
            .map(MenuMeal.init(added:))
    }
}

public extension TripMeal {
    var kind: MealKind {
        get { MealKind(rawValue: kindValue) ?? .other }
        set { kindValue = newValue.rawValue }
    }

    var sortedDishes: [MenuDish] {
        (dishes ?? []).filter { !$0.isDeleted }.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }
    }

    func rename(_ draft: MealDraft) throws {
        let details = draft.cleaned
        try details.validate()
        title = details.title
    }
}

public extension MenuDish {
    var photoData: Data? { protectedPhoto }
    var draft: MenuDishDraft { MenuDishDraft(name: name, notes: notes) }
    var sortedItems: [DishItem] { (items ?? []).filter { !$0.isDeleted }.sorted { $0.position < $1.position } }

    /// Saves the editor's copy. An unchanged photo isn't rewritten, so it isn't uploaded again.
    func update(_ draft: MenuDishDraft, photo: Data?) throws {
        let details = draft.cleaned
        try details.validate()
        name = details.name
        notes = details.notes
        if protectedPhoto != photo { protectedPhoto = photo }
    }

    @discardableResult
    func addItem(_ draft: DishItemDraft) throws -> DishItem {
        let details = draft.cleaned
        try details.validate()
        guard let modelContext else { throw CampError.mealUnavailable }
        let item = DishItem()
        modelContext.insert(item)
        item.name = details.name
        item.quantity = details.quantity
        item.position = (sortedItems.last?.position ?? -1) + 1
        item.dish = self
        return item
    }

    /// Stores the order the list now has, e.g. after a drag.
    func reorderItems(_ ordered: [DishItem]) {
        for (position, item) in ordered.enumerated() where item.position != position { item.position = position }
    }

    func removeItems(_ removed: [DishItem]) {
        for item in removed { modelContext?.delete(item) }
    }
}

public extension DishItem {
    var draft: DishItemDraft { DishItemDraft(name: name, quantity: quantity) }

    func update(_ draft: DishItemDraft) throws {
        let details = draft.cleaned
        try details.validate()
        name = details.name
        quantity = details.quantity
    }
}
