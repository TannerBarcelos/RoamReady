import Foundation
import SwiftData
import CampCore

/// The Grocery list: a trip's ingredients gathered from its menu. Nothing is stored for the list itself;
/// only each ingredient's Have mark and the amounts the camper overrode are saved.
public extension Trip {
    /// Ingredients of meals on the trip's listed days, in menu order. Meals under Outside trip dates
    /// aren't on the list.
    private var groceryItems: [DishItem] {
        menuDays.flatMap { day in menu(on: day.offset).flatMap { $0.dishes.flatMap(\.sortedItems) } }
    }

    /// The list for the menu as it is now.
    var groceryList: GroceryList {
        GroceryList(ingredients: groceryItems.map { GroceryIngredient(name: $0.name, amount: $0.amount, amountText: $0.amountText, have: $0.have) },
                    overrides: (groceryOverrides ?? []).filter { !$0.isDeleted }.map(\.value))
    }

    /// Marks every ingredient behind a row. A row is Have only when all of them are, so checking a mixed
    /// row marks them all Have.
    func setHave(_ have: Bool, forGroceryKey key: String) {
        for item in groceryItems where GroceryList.key(for: item.name) == key && item.have != have { item.have = have }
    }

    /// Sets the amount a row shows, without changing the menu. A nil amount shows none. With duplicate records
    /// from sync, the newest is updated and stays newest.
    func setGroceryAmount(_ amount: IngredientAmount?, forKey key: String) {
        let records = overrideRecords(forKey: key)
        let record: GroceryAmountOverride
        if let newest = records.max(by: { $0.updatedAt < $1.updatedAt }) {
            record = newest
        } else {
            guard let modelContext else { return }
            record = GroceryAmountOverride()
            modelContext.insert(record)
            record.itemKey = key
            record.trip = self
        }
        record.amountValue = amount?.value
        record.unitValue = amount?.unit?.rawValue
        let latest = records.map(\.updatedAt).max()
        record.updatedAt = max(Date.now, latest.map { $0.addingTimeInterval(0.001) } ?? .distantPast)
    }

    /// Returns a row to the menu's total. Deletes every record for the key, since sync can produce more than one.
    func resetGroceryAmount(forKey key: String) {
        for record in overrideRecords(forKey: key) { modelContext?.delete(record) }
    }

    private func overrideRecords(forKey key: String) -> [GroceryAmountOverride] {
        (groceryOverrides ?? []).filter { !$0.isDeleted && $0.itemKey == key }
    }
}

extension GroceryAmountOverride {
    /// The amount, or nil for none or a unit this app version doesn't know.
    var amount: IngredientAmount? { StoredAmount.amount(value: amountValue, unit: unitValue) }
    var amountText: String { StoredAmount.text(value: amountValue, unit: unitValue) }
    var value: GroceryOverride { GroceryOverride(key: itemKey, amount: amount, amountText: amountText, updatedAt: updatedAt) }
}

/// A stored number and raw unit, shared by ingredients and the amounts a camper set on the Grocery list.
enum StoredAmount {
    /// Nil when there is no amount, or the unit is one this version doesn't know (it would otherwise be
    /// summed with unitless amounts); `text` still shows those.
    static func amount(value: Double?, unit: String?) -> IngredientAmount? {
        let known = unit.flatMap(IngredientUnit.init(rawValue:))
        guard let value, unit == nil || known != nil else { return nil }
        return IngredientAmount(value, unit: known)
    }

    /// "2 lb", "1½ cup", "6", or "" when there is no amount. An unknown unit is shown as it was saved.
    static func text(value: Double?, unit: String?) -> String {
        guard let value, value.isFinite, value > 0 else { return "" }
        let number = IngredientAmount.text(for: value)
        guard let unit, !unit.isEmpty else { return number }
        return "\(number) \(IngredientUnit(rawValue: unit)?.title ?? unit)"
    }
}
