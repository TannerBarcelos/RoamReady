import Foundation
import Testing
@testable import CampCore

struct GroceryListTests {
    private func ingredient(_ name: String, _ value: Double? = nil, _ unit: IngredientUnit? = nil, have: Bool = false,
                            category: IngredientCategory = .other) -> GroceryIngredient {
        GroceryIngredient(name: name, amount: value.flatMap { IngredientAmount($0, unit: unit) }, have: have, category: category)
    }

    private func override(_ key: String, _ value: Double?, _ unit: IngredientUnit? = nil, at seconds: TimeInterval = 0) -> GroceryOverride {
        GroceryOverride(key: key, amount: value.flatMap { IngredientAmount($0, unit: unit) }, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Merging

    @Test func namesMergeIgnoringCaseSurroundingSpaceAndRepeatedInnerSpaces() {
        let list = GroceryList(ingredients: [
            ingredient("Ribeye", 2, .lb), ingredient("  ribeye ", 1, .lb), ingredient("RIBEYE", 0.5, .lb),
            ingredient("Brussels   sprouts"), ingredient("brussels sprouts"), ingredient("Brussels\tsprouts"),
        ])
        #expect(list.rows.map(\.name) == ["Brussels   sprouts", "Ribeye"])
        #expect(list.rows.map(\.ingredientCount) == [3, 3])
        #expect(list.rows[1].amountText == "3½ lb")
    }

    @Test func eggAndEggsStayTwoRows() {
        let list = GroceryList(ingredients: [ingredient("Egg", 1), ingredient("Eggs", 6)])
        #expect(list.rows.map(\.name) == ["Egg", "Eggs"])
    }

    @Test func theFirstSeenSpellingIsShown() {
        let list = GroceryList(ingredients: [ingredient("  Olive Oil "), ingredient("olive oil"), ingredient("OLIVE OIL")])
        #expect(list.rows.map(\.name) == ["Olive Oil"])
    }

    @Test func aBlankNameIsNotARow() {
        #expect(GroceryList(ingredients: [ingredient("   ")]).isEmpty)
        #expect(GroceryList.key(for: " \t ") == "")
    }

    @Test func theKeyIsCaseFoldedAndSingleSpaced() {
        #expect(GroceryList.key(for: "  Brussels \n SPROUTS ") == "brussels sprouts")
        #expect(GroceryList.key(for: "Eggs") != GroceryList.key(for: "Egg"))
    }

    // MARK: Amounts

    @Test func amountsWithTheSameUnitAddUpAndOtherUnitsStaySideBySide() {
        let list = GroceryList(ingredients: [ingredient("Eggs", 1, .dozen), ingredient("Eggs", 6), ingredient("Eggs", 1, .dozen)])
        #expect(list.rows[0].amountText == "2 dozen, 6")
        let first = GroceryList(ingredients: [ingredient("Eggs", 6), ingredient("Eggs", 1, .dozen)])
        #expect(first.rows[0].amountText == "6, 1 dozen", "Totals keep the order each unit first appears")
    }

    @Test func fractionsAddUpToReadableTotals() {
        let list = GroceryList(ingredients: [ingredient("Milk", 0.5, .cup), ingredient("Milk", 0.75, .cup)])
        #expect(list.rows[0].amountText == "1¼ cup")
    }

    @Test func anIngredientWithNoAmountAddsNothingToTheText() {
        let list = GroceryList(ingredients: [ingredient("Salt"), ingredient("Salt"), ingredient("Pepper", 1, .bunch), ingredient("Pepper")])
        #expect(list.rows.map(\.amountText) == ["1 bunch", ""])
        #expect(list.rows.map(\.line) == ["Pepper: 1 bunch", "Salt"])
    }

    @Test func anUnknownUnitShowsAsSavedAlongsideTheTotals() {
        let unknown = GroceryIngredient(name: "Cheese", amount: nil, amountText: "2 wheel")
        let list = GroceryList(ingredients: [ingredient("Cheese", 1, .lb), unknown, ingredient("Cheese", 2, .lb)])
        #expect(list.rows[0].amountText == "3 lb, 2 wheel")
        #expect(list.rows[0].editableAmount == nil, "A mix isn't one amount to start from")
    }

    // MARK: Order

    @Test func rowsSortAlphabeticallyTheWayTheSystemDoes() {
        let list = GroceryList(ingredients: ["zucchini", "Apples", "bacon", "Éclair", "Apple", "item 10", "item 2"].map { ingredient($0) })
        #expect(list.rows.map(\.name) == ["Apple", "Apples", "bacon", "Éclair", "item 2", "item 10", "zucchini"])
    }

    // MARK: Have and Need

    @Test func aRowIsHaveOnlyWhenEveryIngredientBehindItIs() {
        let allHave = GroceryList(ingredients: [ingredient("Eggs", 6, have: true), ingredient("Eggs", 6, have: true)])
        #expect(allHave.rows[0].isHave)
        let mixed = GroceryList(ingredients: [ingredient("Eggs", 6, have: true), ingredient("eggs", 6, have: false)])
        #expect(!mixed.rows[0].isHave, "A newly added ingredient sends the row back to Need")
        #expect(mixed.need.map(\.name) == ["Eggs"] && mixed.have.isEmpty)
    }

    @Test func needAndHaveSplitTheRowsInOrder() {
        let list = GroceryList(ingredients: [ingredient("Butter", have: true), ingredient("Eggs"), ingredient("Ham"), ingredient("Jam", have: true)])
        #expect(list.need.map(\.name) == ["Eggs", "Ham"])
        #expect(list.have.map(\.name) == ["Butter", "Jam"])
    }

    @Test func progressReadsHowManyAreLeft() {
        #expect(GroceryList.empty.progressText == "No ingredients")
        let some = GroceryList(ingredients: [ingredient("A"), ingredient("B", have: true), ingredient("C"), ingredient("D", have: true)])
        #expect(some.progressText == "2 of 4 left")
        #expect(!some.needsNothing)
        let all = GroceryList(ingredients: [ingredient("A", have: true), ingredient("B", have: true)])
        #expect(all.progressText == "All set")
        #expect(all.needsNothing)
        #expect(GroceryList(ingredients: [ingredient("A", have: true), ingredient("a")]).progressText == "1 of 1 left", "Merged rows count once")
    }

    // MARK: Overrides

    @Test func anOverrideReplacesTheAmountAndTheMenuLineShowsTheTotal() throws {
        let list = GroceryList(ingredients: [ingredient("Ribeye", 2, .lb), ingredient("ribeye", 1, .lb)],
                               overrides: [override("ribeye", 5, .lb)])
        let row = try #require(list.rows.first)
        #expect(row.amountText == "5 lb")
        #expect(row.menuAmountText == "3 lb")
        #expect(row.isOverridden)
        #expect(row.menuLine == "Menu: 3 lb")
        #expect(row.line == "Ribeye: 5 lb")
        #expect(row.editableAmount == IngredientAmount(5, unit: .lb))
    }

    @Test func anOverrideStaysWhenTheMenuGrows() throws {
        let overrides = [override("ribeye", 5, .lb)]
        let grown = GroceryList(ingredients: [ingredient("Ribeye", 4, .lb)], overrides: overrides)
        #expect(grown.rows[0].amountText == "5 lb")
        #expect(grown.rows[0].menuLine == "Menu: 4 lb")
    }

    @Test func anOverrideMatchingTheMenuShowsNoMenuLine() {
        let list = GroceryList(ingredients: [ingredient("Ribeye", 3, .lb)], overrides: [override("ribeye", 3, .lb)])
        #expect(list.rows[0].amountText == "3 lb")
        #expect(!list.rows[0].isOverridden)
        #expect(list.rows[0].menuLine == nil)
    }

    @Test func anOverrideWithNoAmountShowsNoneAndTheMenuLine() {
        let list = GroceryList(ingredients: [ingredient("Ribeye", 3, .lb)], overrides: [override("ribeye", nil)])
        #expect(list.rows[0].amountText == "")
        #expect(list.rows[0].menuLine == "Menu: 3 lb")
        let none = GroceryList(ingredients: [ingredient("Salt")], overrides: [override("salt", 1, .bag)])
        #expect(none.rows[0].menuLine == "Menu: no amount")
    }

    @Test func anOverrideForAnotherNameIsNotShown() {
        let list = GroceryList(ingredients: [ingredient("Ribeye", 3, .lb)], overrides: [override("brisket", 5, .lb)])
        #expect(list.rows.map(\.name) == ["Ribeye"])
        #expect(list.rows[0].amountText == "3 lb")
        #expect(list.rows[0].override == nil)
    }

    @Test func theNewestOfDuplicateOverridesWins() {
        let list = GroceryList(ingredients: [ingredient("Ribeye", 3, .lb)], overrides: [
            override("ribeye", 8, .lb, at: 200), override("ribeye", 5, .lb, at: 300), override("ribeye", 2, .lb, at: 100)])
        #expect(list.rows[0].amountText == "5 lb")
    }

    @Test func aRowStartsEditingFromTheMenuTotalWhenItIsOneKnownAmount() {
        #expect(GroceryList(ingredients: [ingredient("Ribeye", 2, .lb), ingredient("Ribeye", 1, .lb)]).rows[0].editableAmount == IngredientAmount(3, unit: .lb))
        #expect(GroceryList(ingredients: [ingredient("Eggs", 1, .dozen), ingredient("Eggs", 6)]).rows[0].editableAmount == nil)
        #expect(GroceryList(ingredients: [ingredient("Salt")]).rows[0].editableAmount == nil)
    }

    // MARK: Sharing

    @Test func theShareTextGroupsNeedRowsByCategoryUnderTheCampgroundUsingOverriddenAmounts() {
        let list = GroceryList(ingredients: [
            ingredient("Ribeye", 3, .lb, category: .meatSeafood), ingredient("Eggs", 1, .dozen, category: .dairyEggs),
            ingredient("Eggs", 6), ingredient("Salt"), ingredient("Potatoes", 4, category: .produce),
            ingredient("Butter", 1, .lb, have: true, category: .dairyEggs),
        ], overrides: [override("ribeye", 5, .lb)])
        #expect(list.shareText(campground: " Pinecrest Lake ") == """
        Grocery list for Pinecrest Lake

        Produce
        Potatoes: 4

        Meat & Seafood
        Ribeye: 5 lb

        Dairy & Eggs
        Eggs: 1 dozen, 6

        Other
        Salt
        """)
    }

    @Test func theShareTextIsEmptyWhenNothingIsNeededAndNamesNothingWithoutACampground() {
        let done = GroceryList(ingredients: [ingredient("Butter", have: true)])
        #expect(done.shareText(campground: "Pinecrest Lake") == "")
        #expect(GroceryList.empty.shareText(campground: "Pinecrest Lake") == "")
        #expect(GroceryList(ingredients: [ingredient("Butter")]).shareText(campground: "  ") == "Grocery list\n\nOther\nButter")
    }

    // MARK: Categories

    @Test func aRowTakesTheFirstCategoryThatIsNotOther() {
        let list = GroceryList(ingredients: [
            ingredient("Butter"), ingredient("butter", category: .dairyEggs), ingredient("BUTTER", category: .bakery),
            ingredient("Salt"), ingredient("salt"),
            ingredient("Milk", category: .beverages), ingredient("milk", category: .dairyEggs),
        ])
        #expect(list.rows.map(\.category) == [.dairyEggs, .beverages, .other])
        #expect(list.rows.map(\.name) == ["Butter", "Milk", "Salt"])
    }

    @Test func needIsSplitByCategoryInTheListsOrderAndHaveStaysFlat() {
        let list = GroceryList(ingredients: [
            ingredient("Zucchini", category: .produce), ingredient("Apples", category: .produce), ingredient("Salt"),
            ingredient("Bread", category: .bakery), ingredient("Soda", category: .beverages),
            ingredient("Yogurt", have: true, category: .dairyEggs), ingredient("Bagels", have: true, category: .bakery),
            ingredient("Ham", category: .meatSeafood),
        ])
        #expect(list.needSections.map(\.category) == [.produce, .meatSeafood, .bakery, .beverages, .other])
        #expect(list.needSections.map { $0.rows.map(\.name) } == [["Apples", "Zucchini"], ["Ham"], ["Bread"], ["Soda"], ["Salt"]])
        #expect(list.have.map(\.name) == ["Bagels", "Yogurt"], "Have is one alphabetical group")
        #expect(GroceryList(ingredients: [ingredient("Yogurt", have: true)]).needSections.isEmpty)
    }

    @Test func theCategoriesKeepTheirOrderAndStoredNames() {
        #expect(IngredientCategory.allCases.map(\.rawValue) == [
            "Produce", "Meat & Seafood", "Dairy & Eggs", "Bakery", "Frozen", "Canned Goods", "Pasta & Grains",
            "Breakfast & Cereal", "Condiments & Spices", "Snacks", "Beverages", "Paper & Household", "Other"])
        #expect(IngredientCategory.allCases.last == .other)
        #expect(DishItemDraft(name: "Eggs").category == .other)
        #expect(DishItemDraft(name: " Eggs ", category: .dairyEggs).cleaned.category == .dairyEggs)
    }
}
