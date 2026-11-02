import Foundation
import Testing
@testable import CampCore

struct IngredientAmountTests {
    @Test func theUnitsAreTheSpecifiedListWithShortTitles() {
        #expect(IngredientUnit.allCases.map(\.title) == ["lb", "oz", "g", "kg", "gal", "qt", "pt", "cup", "fl oz", "tbsp", "tsp", "L", "mL",
                                                         "dozen", "pack", "can", "bottle", "bag", "box", "bunch", "loaf", "slice"])
        #expect(Set(IngredientUnit.allCases.map(\.rawValue)).count == IngredientUnit.allCases.count)
        #expect(IngredientUnit.flOz.rawValue == "flOz", "The stored value is fixed once shipped")
    }

    @Test func theChoicesAreFractionsThenWholeNumbersToFifty() {
        let choices = IngredientAmount.choices
        #expect(choices.count == 10 + 47)
        #expect(choices.prefix(10).map { IngredientAmount.text(for: $0) } == ["¼", "⅓", "½", "⅔", "¾", "1", "1½", "2", "2½", "3"])
        #expect(Array(choices.suffix(47)) == (4...50).map(Double.init))
        #expect(choices == choices.sorted())
    }

    @Test func aPickerKeepsAValueItDoesNotOffer() {
        #expect(IngredientAmount.choices(including: nil) == IngredientAmount.choices)
        #expect(IngredientAmount.choices(including: 2) == IngredientAmount.choices)
        #expect(IngredientAmount.choices(including: 1.0 / 3.0 + 1e-12) == IngredientAmount.choices)
        let withSixty = IngredientAmount.choices(including: 60)
        #expect(withSixty.last == 60 && withSixty.count == IngredientAmount.choices.count + 1)
        let withOdd = IngredientAmount.choices(including: 0.58)
        #expect(withOdd.firstIndex(of: 0.58) == 3, "Placed among the choices in order")
        #expect(IngredientAmount.choices(including: -1) == IngredientAmount.choices)
        #expect(IngredientAmount.choices(including: .nan) == IngredientAmount.choices)
    }

    @Test func amountsFormatLikeTheOwnerWouldWriteThem() throws {
        #expect(try #require(IngredientAmount(2, unit: .lb)).text == "2 lb")
        #expect(try #require(IngredientAmount(1.5, unit: .cup)).text == "1½ cup")
        #expect(try #require(IngredientAmount(6)).text == "6")
        #expect(try #require(IngredientAmount(0.25, unit: .tsp)).text == "¼ tsp")
        #expect(try #require(IngredientAmount(8, unit: .flOz)).text == "8 fl oz")
        #expect(try #require(IngredientAmount(2, unit: .liter)).text == "2 L")
        #expect(try #require(IngredientAmount(500, unit: .milliliter)).text == "500 mL")
    }

    @Test func valuesOutsideThePickerStillFormat() throws {
        #expect(IngredientAmount.text(for: 1.0 / 3.0 + 1.0 / 3.0) == "⅔", "1/3 + 1/3 is not 0.67")
        #expect(IngredientAmount.text(for: 1.0 / 3.0 + 2.0 / 3.0) == "1")
        #expect(IngredientAmount.text(for: 0.1 + 0.2 + 0.7) == "1", "Floating-point error is not shown")
        #expect(IngredientAmount.text(for: 4 + 1.0 / 3.0) == "4⅓")
        #expect(IngredientAmount.text(for: 0.5 + 1.0 / 3.0) == "⅚")
        #expect(IngredientAmount.text(for: 0.75 + 0.75) == "1½")
        #expect(IngredientAmount.text(for: 0.125) == "⅛")
        #expect(IngredientAmount.text(for: 7.0 / 12.0) == "0.58", "Not a common fraction: at most 2 decimals")
        #expect(IngredientAmount.text(for: 12.349) == "12.35")
        #expect(IngredientAmount.text(for: 2.001) == "2")
        #expect(IngredientAmount.text(for: 0.1) == "0.1")
        #expect(IngredientAmount.text(for: 1_234.5) == "1234½")
        #expect(IngredientAmount.text(for: 1_234_567.0) == "1234567")
        #expect(IngredientAmount.text(for: 2.999_999_9) == "3")
        #expect(IngredientAmount.text(for: .infinity) == "")
    }

    @Test func onlyPositiveFiniteNumbersAreAmounts() {
        #expect(IngredientAmount(0) == nil)
        #expect(IngredientAmount(-1, unit: .lb) == nil)
        #expect(IngredientAmount(.nan) == nil)
        #expect(IngredientAmount(.infinity) == nil)
    }

    @Test func amountsRoundTripThroughCodableAndRejectBadNumbers() throws {
        let amount = try #require(IngredientAmount(1.5, unit: .flOz))
        let data = try JSONEncoder().encode(amount)
        #expect(try JSONDecoder().decode(IngredientAmount.self, from: data) == amount)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(IngredientAmount.self, from: Data(#"{"value":-2}"#.utf8)) }
        #expect(try JSONDecoder().decode(IngredientAmount.self, from: Data(#"{"value":3}"#.utf8)) == IngredientAmount(3))
    }

    @Test func amountsWithTheSameUnitAddUp() throws {
        let third = try #require(IngredientAmount(1.0 / 3.0, unit: .cup))
        let sum = try #require(third.adding(third))
        #expect(sum.text == "⅔ cup")
        #expect(try #require(sum.adding(third)).text == "1 cup")
        #expect(third.adding(try #require(IngredientAmount(1, unit: .tbsp))) == nil, "Different units are not added")
        #expect(third.adding(try #require(IngredientAmount(1))) == nil, "A number alone is its own kind")
    }

    @Test func totalsGroupByUnitInFirstSeenOrder() throws {
        let amounts = try [(2.0, IngredientUnit?.some(.lb)), (1, nil), (0.5, .lb), (6, nil), (1, .can)]
            .map { try #require(IngredientAmount($0.0, unit: $0.1)) }
        #expect(IngredientAmount.totals(of: amounts).map(\.text) == ["2½ lb", "7", "1 can"])
        #expect(IngredientAmount.totals(of: []).isEmpty)
    }

    @Test func draftsDropWhatCannotBeAnAmount() {
        #expect(DishItemDraft(name: " Ribeye ", amount: 2, unit: .lb).cleaned == DishItemDraft(name: "Ribeye", amount: 2, unit: .lb))
        #expect(DishItemDraft(name: "Eggs", amount: 6).cleaned == DishItemDraft(name: "Eggs", amount: 6), "A number alone is valid")
        #expect(DishItemDraft(name: "Salt").cleaned == DishItemDraft(name: "Salt"), "No amount is valid")
        #expect(DishItemDraft(name: "Salt", amount: nil, unit: .oz).cleaned == DishItemDraft(name: "Salt"), "A unit needs a number")
        #expect(DishItemDraft(name: "Salt", amount: 0, unit: .oz).cleaned == DishItemDraft(name: "Salt"))
        #expect(DishItemDraft(name: "Salt", amount: -2, unit: .oz).cleaned == DishItemDraft(name: "Salt"))
        #expect(DishItemDraft(name: "Salt", amount: .nan, unit: .oz).cleaned == DishItemDraft(name: "Salt"))
        #expect(DishItemDraft(name: "Salt", amount: .infinity).cleaned == DishItemDraft(name: "Salt"))
        #expect(DishItemDraft(name: "Eggs", amount: 6).ingredientAmount == IngredientAmount(6))
        #expect(DishItemDraft(name: "Eggs", unit: .dozen).ingredientAmount == nil)
    }
}
