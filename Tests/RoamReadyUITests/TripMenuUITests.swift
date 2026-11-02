import XCTest

/// Trip menus: planning a dish and its ingredients from Trip details, and Home's menu shortcut, which is
/// held above the split view so a fold or resize keeps it open.
@MainActor
final class TripMenuUITests: XCTestCase {
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-layout-ui-test"]
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
        button.tap()
        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    func testPlanningADishAndItsIngredientsFromTripDetails() {
        let app = launch()
        tapReachable(app.buttons["tripRow-Upcoming Lake"], in: app)
        XCTAssertTrue(app.navigationBars["Upcoming Lake"].waitForExistence(timeout: 5))
        tapReachable(app.buttons["tripMenu"], in: app)
        XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Create menu"].exists, "An empty menu invites creating one")

        tapReachable(app.buttons["menuMeal-1-dinner"], in: app)
        XCTAssertTrue(app.navigationBars["Dinner"].waitForExistence(timeout: 5))
        app.buttons["addDish"].tap()
        XCTAssertTrue(app.navigationBars["New dish"].waitForExistence(timeout: 5))
        type("Foil packs", into: "menuDishName", in: app)
        app.buttons["Save"].tap()

        tapReachable(app.buttons["menuDish-Foil packs"], in: app)
        XCTAssertTrue(app.navigationBars["Foil packs"].waitForExistence(timeout: 5))
        app.buttons["addDishItem"].tap()
        XCTAssertTrue(app.navigationBars["New ingredient"].waitForExistence(timeout: 5))
        type("Potatoes", into: "dishItemName", in: app)
        XCTAssertFalse(app.buttons["dishItemUnit"].isEnabled, "A unit needs an amount")
        choose("4", from: "dishItemAmount", in: app)
        XCTAssertTrue(app.buttons["dishItemUnit"].isEnabled)
        app.buttons["saveAndAddDishItem"].tap()
        XCTAssertTrue(app.staticTexts["1 ingredient added"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["dishItemAmount"].label, "Amount, None", "Save & add another resets the amount")
        XCTAssertFalse(app.buttons["dishItemUnit"].isEnabled)
        type("Sausage", into: "dishItemName", in: app)
        choose("1½", from: "dishItemAmount", in: app)
        choose("lb", from: "dishItemUnit", in: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["dishItem-Potatoes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dishItem-Sausage"].exists)
        XCTAssertTrue(app.staticTexts["4"].exists)
        XCTAssertTrue(app.staticTexts["1½ lb"].exists)
        XCTAssertTrue(app.staticTexts["Ingredients · 2"].exists)

        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Dinner"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 dish · 1 meal"].waitForExistence(timeout: 5))
    }

    func testAddingAMealToADay() {
        let app = launch()
        tapReachable(app.buttons["tripRow-Upcoming Lake"], in: app)
        tapReachable(app.buttons["tripMenu"], in: app)
        tapReachable(app.buttons["addMeal-1"], in: app)
        type("Second breakfast", into: "menuMealName", in: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["menuMeal-1-Second breakfast"].waitForExistence(timeout: 5))
    }

    func testRepeatingABreakfastOnAllDays() {
        let app = launch()
        tapReachable(app.buttons["tripRow-Upcoming Lake"], in: app)
        tapReachable(app.buttons["tripMenu"], in: app)
        tapReachable(app.buttons["menuMeal-1-breakfast"], in: app)
        XCTAssertFalse(app.buttons["repeatMeal"].exists, "Nothing to repeat until a dish is planned")
        app.buttons["addDish"].tap()
        type("Oatmeal", into: "menuDishName", in: app)
        app.buttons["Save"].tap()

        tapReachable(app.buttons["repeatMeal"], in: app)
        XCTAssertTrue(app.switches["repeatAllDays"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["repeatDay-1"].exists, "The day being repeated isn't listed")
        XCTAssertTrue(app.switches["repeatDay-2"].exists && app.switches["repeatDay-3"].exists)
        XCTAssertFalse(app.buttons["Repeat"].isEnabled, "Pick a day first")
        // The row's label isn't a hit target; the switch itself is at the trailing edge.
        app.switches["repeatAllDays"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["repeatDay-2"].value as? String, "1")
        XCTAssertTrue(app.buttons["Repeat"].isEnabled)
        app.buttons["Repeat"].tap()
        XCTAssertFalse(app.switches["repeatAllDays"].waitForExistence(timeout: 2), "The sheet closes on success")

        app.buttons["BackButton"].firstMatch.tap()
        tapReachable(app.buttons["menuMeal-3-breakfast"], in: app)
        XCTAssertTrue(app.buttons["menuDish-Oatmeal"].waitForExistence(timeout: 5))
    }

    func testHomeMenuShortcutStaysOpenThroughAResize() {
        let app = launch()
        tapReachable(app.buttons["homeMenu"], in: app)
        XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 5))
        let marker = app.descendants(matching: .any)["homeDetailMenu"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertEqual(marker.label, "Menu")
        XCTAssertEqual(app.descendants(matching: .any)["homeDetailTrip"].label, "Current Pines")

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 5))
            XCTAssertEqual(marker.label, "Menu", "Home keeps the open menu across layout changes")
        }
        XCTAssertTrue(app.buttons["menuMeal-1-dinner"].exists)
    }
}
