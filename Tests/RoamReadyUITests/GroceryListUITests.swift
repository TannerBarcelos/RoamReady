import XCTest

/// The Grocery list: opened from Trip details once a dish has ingredients, checking a row into Have,
/// and changing a row's amount without changing the menu.
@MainActor
final class GroceryListUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    private func tapReachable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func type(_ text: String, into identifier: String, in app: XCUIApplication) {
        let field = app.textFields[identifier].exists ? app.textFields[identifier] : app.textViews[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    /// Opens a menu-style picker and picks one of its options.
    private func choose(_ option: String, from picker: String, in app: XCUIApplication) {
        let button = app.buttons[picker]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let choice = app.buttons[option].firstMatch
        // The keyboard can cover pickers lower in the form, and a menu occasionally opens late or not at all.
        for _ in 0..<3 {
            for _ in 0..<3 where !button.isHittable { app.swipeUp() }
            button.tap()
            if choice.waitForExistence(timeout: 3) { break }
            // A long menu opens scrolled to the current choice, so the first options can be above the screen.
            let anchor = app.buttons["Bakery"].firstMatch
            for _ in 0..<3 where anchor.exists && !choice.exists { anchor.swipeDown() }
            if choice.exists { break }
        }
        XCTAssertTrue(choice.exists, "\(option) is in the \(picker) menu")
        choice.tap()
    }

    /// Plans "Foil packs" for the first dinner of Upcoming Lake with two ingredients, then returns to Trip details.
    private func planFoilPacks(in app: XCUIApplication) {
        tapReachable(app.buttons["tripRow-Upcoming Lake"], in: app)
        XCTAssertTrue(app.navigationBars["Upcoming Lake"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tripGroceryList"].exists, "No ingredients, no grocery list")
        tapReachable(app.buttons["tripMenu"], in: app)
        XCTAssertFalse(app.buttons["menuGroceryList"].exists)
        tapReachable(app.buttons["menuMeal-1-dinner"], in: app)
        app.buttons["addDish"].tap()
        type("Foil packs", into: "menuDishName", in: app)
        app.buttons["Save"].tap()
        tapReachable(app.buttons["menuDish-Foil packs"], in: app)
        app.buttons["addDishItem"].tap()
        type("Potatoes", into: "dishItemName", in: app)
        choose("4", from: "dishItemAmount", in: app)
        XCTAssertEqual(app.buttons["dishItemCategory"].label, "Category, Other", "Category defaults to Other")
        choose("Produce", from: "dishItemCategory", in: app)
        app.buttons["saveAndAddDishItem"].tap()
        XCTAssertTrue(app.staticTexts["1 ingredient added"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["dishItemCategory"].label, "Category, Other", "Save & add another resets the category")
        type("Sausage", into: "dishItemName", in: app)
        choose("1½", from: "dishItemAmount", in: app)
        choose("lb", from: "dishItemUnit", in: app)
        choose("Meat & Seafood", from: "dishItemCategory", in: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["dishItem-Sausage"].waitForExistence(timeout: 5))

        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["menuGroceryList"].waitForExistence(timeout: 5), "The Menu links to the list too")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tripGroceryList"].waitForExistence(timeout: 5))
    }

    private func changeAmount(of row: XCUIElement, in app: XCUIApplication) {
        row.swipeLeft()
        let action = app.buttons["Change amount"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(app.navigationBars["Change amount"].waitForExistence(timeout: 5))
    }

    func testCheckingARowMovesItToHave() {
        let app = launch()
        planFoilPacks(in: app)
        XCTAssertTrue(app.staticTexts["2 of 2 left"].exists)
        tapReachable(app.buttons["tripGroceryList"], in: app)
        XCTAssertTrue(app.navigationBars["Grocery list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shareGroceryList"].exists)

        let potatoes = app.buttons["groceryRow-Potatoes"]
        XCTAssertTrue(potatoes.waitForExistence(timeout: 5))
        XCTAssertEqual(potatoes.value as? String, "Need")
        XCTAssertTrue(app.staticTexts["Produce"].exists, "Need is grouped by category")
        XCTAssertTrue(app.staticTexts["Meat & Seafood"].exists)
        XCTAssertFalse(app.staticTexts["Have"].exists)

        potatoes.tap()
        XCTAssertTrue(app.staticTexts["Have"].waitForExistence(timeout: 5), "A checked row moves under Have")
        XCTAssertEqual(app.buttons["groceryRow-Potatoes"].value as? String, "Have")
        XCTAssertFalse(app.staticTexts["Produce"].exists, "A category with nothing left to get is hidden")
        XCTAssertEqual(app.buttons["groceryRow-Sausage"].value as? String, "Need")
        XCTAssertTrue(app.staticTexts["1 of 2 left"].exists)

        app.buttons["groceryRow-Sausage"].tap()
        XCTAssertTrue(app.staticTexts["You have everything"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["shareGroceryList"].exists, "Nothing in Need to share")
        XCTAssertTrue(app.staticTexts["All set"].exists)

        app.buttons["groceryRow-Potatoes"].tap()
        XCTAssertTrue(app.buttons["shareGroceryList"].waitForExistence(timeout: 5), "Unchecking brings Need back")

        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 of 2 left"].waitForExistence(timeout: 5), "Trip details shows the progress")
    }

    func testChangingARowsAmountLeavesTheMenuAloneAndResetGoesBack() {
        let app = launch()
        planFoilPacks(in: app)
        tapReachable(app.buttons["tripGroceryList"], in: app)
        let sausage = app.buttons["groceryRow-Sausage"]
        XCTAssertTrue(sausage.waitForExistence(timeout: 5))
        XCTAssertTrue(sausage.label.contains("1½ lb"))
        XCTAssertFalse(sausage.label.contains("Menu:"))

        changeAmount(of: sausage, in: app)
        XCTAssertFalse(app.buttons["groceryResetAmount"].exists, "Nothing to reset yet")
        choose("5", from: "groceryAmount", in: app)
        app.buttons["groceryAmountSave"].tap()
        XCTAssertTrue(app.navigationBars["Grocery list"].waitForExistence(timeout: 5))
        XCTAssertTrue(sausage.label.contains("5 lb"), sausage.label)
        XCTAssertTrue(sausage.label.contains("Menu: 1½ lb"), sausage.label)

        changeAmount(of: sausage, in: app)
        app.buttons["groceryResetAmount"].tap()
        XCTAssertTrue(app.navigationBars["Grocery list"].waitForExistence(timeout: 5))
        XCTAssertTrue(sausage.label.contains("1½ lb"), sausage.label)
        XCTAssertFalse(sausage.label.contains("Menu:"), sausage.label)

        app.buttons["BackButton"].firstMatch.tap()
        tapReachable(app.buttons["tripMenu"], in: app)
        tapReachable(app.buttons["menuMeal-1-dinner"], in: app)
        tapReachable(app.buttons["menuDish-Foil packs"], in: app)
        XCTAssertTrue(app.staticTexts["1½ lb"].exists, "The ingredient was never changed")
    }
}
