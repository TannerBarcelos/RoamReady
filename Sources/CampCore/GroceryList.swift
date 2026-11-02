import Foundation

/// One ingredient as the Grocery list sees it: plain values copied from the Menu, so the rules here
/// need no SwiftData.
public struct GroceryIngredient: Equatable, Sendable {
    public let name: String
    /// Nil when there is none, or when the stored unit is one this app version doesn't know.
    public let amount: IngredientAmount?
    /// Shown alongside the totals when `amount` is nil. Empty when the ingredient has no amount.
    public let amountText: String
    /// Have, not Need.
    public let have: Bool

    public init(name: String, amount: IngredientAmount? = nil, amountText: String? = nil, have: Bool = false) {
        self.name = name; self.amount = amount; self.have = have
        self.amountText = amountText ?? amount?.text ?? ""
    }
}

/// A different amount the camper set on one row of the Grocery list. The Menu isn't changed.
public struct GroceryOverride: Equatable, Sendable {
    /// The row's merge key, see `GroceryList.key(for:)`.
    public let key: String
    /// Nil means the camper chose no amount, or the stored unit is unknown (then `amountText` says it).
    public let amount: IngredientAmount?
    public let amountText: String
    public let updatedAt: Date

    public init(key: String, amount: IngredientAmount?, amountText: String? = nil, updatedAt: Date) {
        self.key = key; self.amount = amount; self.updatedAt = updatedAt
        self.amountText = amountText ?? amount?.text ?? ""
    }
}

/// A trip's Ingredients gathered from its Menu into one row per name. It is rebuilt from the current
/// menu whenever it is read, so it never goes stale; the only things kept for it are each ingredient's
/// Have mark and any amount the camper overrode.
public struct GroceryList: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        /// The merge key; `GroceryList.key(for:)` of the name.
        public let key: String
        /// The first-seen spelling.
        public let name: String
        /// How many ingredients are merged into this row.
        public let ingredientCount: Int
        /// Have only when every merged ingredient is. A mix reads as Need.
        public let isHave: Bool
        /// The menu's totals, one per unit, in the order each unit first appears.
        public let menuTotals: [IngredientAmount]
        /// The amounts of ingredients whose unit this version doesn't know, shown as they were saved.
        public let menuUnknownTexts: [String]
        public let override: GroceryOverride?

        public var id: String { key }

        /// What the menu adds up to, like "1 dozen, 6". Empty when no ingredient has an amount.
        public var menuAmountText: String { (menuTotals.map(\.text) + menuUnknownTexts).joined(separator: ", ") }

        /// What the row shows: the camper's amount when they set one, otherwise the menu's.
        public var amountText: String { override?.amountText ?? menuAmountText }

        /// True when the camper's amount differs from the menu's.
        public var isOverridden: Bool { override != nil && override?.amountText != menuAmountText }

        /// "Menu: 3 lb" under an overridden row, nil otherwise.
        public var menuLine: String? {
            guard isOverridden else { return nil }
            return menuAmountText.isEmpty ? "Menu: no amount" : "Menu: \(menuAmountText)"
        }

        /// Where the amount editor starts: the camper's amount, else the menu's when it is one known amount.
        public var editableAmount: IngredientAmount? {
            if let override { return override.amount }
            return menuTotals.count == 1 && menuUnknownTexts.isEmpty ? menuTotals[0] : nil
        }

        /// "Eggs" or "Eggs: 1 dozen, 6".
        public var line: String { amountText.isEmpty ? name : "\(name): \(amountText)" }
    }

    /// Every row, sorted by name.
    public let rows: [Row]

    public static let empty = GroceryList(ingredients: [])

    /// `ingredients` in menu order: the first spelling of a name that appears is the one shown.
    /// With several `overrides` for one row, the newest wins.
    public init(ingredients: [GroceryIngredient], overrides: [GroceryOverride] = []) {
        var order: [String] = [], groups: [String: [GroceryIngredient]] = [:]
        for ingredient in ingredients {
            let key = Self.key(for: ingredient.name)
            guard !key.isEmpty else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(ingredient)
        }
        var newest: [String: GroceryOverride] = [:]
        for override in overrides where override.updatedAt >= (newest[override.key]?.updatedAt ?? .distantPast) {
            newest[override.key] = override
        }
        rows = order.compactMap { key -> Row? in
            guard let group = groups[key], let first = group.first else { return nil }
            return Row(key: key, name: first.name.trimmingCharacters(in: .whitespacesAndNewlines),
                       ingredientCount: group.count, isHave: group.allSatisfy(\.have),
                       menuTotals: IngredientAmount.totals(of: group.compactMap(\.amount)),
                       menuUnknownTexts: group.filter { $0.amount == nil && !$0.amountText.isEmpty }.map(\.amountText),
                       override: newest[key])
        }
        .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }
    }

    /// Names merge ignoring case, surrounding whitespace, and repeated inner spaces. "Egg" and "Eggs"
    /// stay separate: nothing guesses plurals. Empty for a blank name.
    public static func key(for name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: .caseInsensitive, locale: nil)
    }

    public var isEmpty: Bool { rows.isEmpty }
    /// Still to get.
    public var need: [Row] { rows.filter { !$0.isHave } }
    /// Bought or already on hand.
    public var have: [Row] { rows.filter(\.isHave) }
    public var needsNothing: Bool { !isEmpty && need.isEmpty }

    /// "3 of 12 left", or "All set" once everything is Have.
    public var progressText: String {
        if isEmpty { return "No ingredients" }
        let left = need.count
        return left == 0 ? "All set" : "\(left) of \(rows.count) left"
    }

    /// The Need rows as plain text for sharing: the campground's name, then one row per line using any
    /// amount the camper set. Empty when there is nothing to get.
    public func shareText(campground: String) -> String {
        let rows = need
        guard !rows.isEmpty else { return "" }
        let name = campground.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([name.isEmpty ? "Grocery list" : "Grocery list for \(name)"] + rows.map(\.line)).joined(separator: "\n")
    }
}
