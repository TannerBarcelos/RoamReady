import Foundation

/// The grocery store section a camper chooses for an ingredient. The order here is the order the
/// Grocery list's Need sections appear in, with `other` last. The raw value (the case name) is what is
/// stored and synced, so it must never change; `title` is free to.
public enum IngredientCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case produce, meatSeafood, dairyEggs, bakery, frozen, cannedGoods, pastaGrains, breakfastCereal, condimentsSpices, snacks, beverages, household, other

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .produce: "Produce"
        case .meatSeafood: "Meat & Seafood"
        case .dairyEggs: "Dairy & Eggs"
        case .bakery: "Bakery"
        case .frozen: "Frozen"
        case .cannedGoods: "Canned Goods"
        case .pastaGrains: "Pasta & Grains"
        case .breakfastCereal: "Breakfast & Cereal"
        case .condimentsSpices: "Condiments & Spices"
        case .snacks: "Snacks"
        case .beverages: "Beverages"
        case .household: "Paper & Household"
        case .other: "Other"
        }
    }
}
