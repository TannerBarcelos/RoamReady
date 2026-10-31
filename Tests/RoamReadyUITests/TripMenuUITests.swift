import XCTest

/// Trip menus: planning a dish and its recipe from Trip details, and Home's menu shortcut, which is
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

    func testPlanningADishAndItsRecipeFromTripDetails() {
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
        type("Potatoes", into: "dishItemName", in: app)
        type("4", into: "dishItemQuantity", in: app)
        app.buttons["saveAndAddDishItem"].tap()
        type("Sausage", into: "dishItemName", in: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["dishItem-Potatoes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dishItem-Sausage"].exists)

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
