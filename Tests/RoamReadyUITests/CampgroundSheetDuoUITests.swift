import XCTest

/// Campground details open in a sheet on Duo (#88), leaving the query and results beneath them.
/// The search goes to Apple Maps, so the test skips when the simulator is offline or finds nothing.
@MainActor
final class CampgroundSheetDuoUITests: XCTestCase {
    func testDetailsOpenInASheetAndDismissingKeepsTheSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-duo-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Camp Finder").waitForExistence(timeout: 10))
        app.navigationTab("Camp Finder").tap()
        if app.staticTexts["Connection needed"].waitForExistence(timeout: 2) {
            throw XCTSkip("Camp Finder needs a network connection on this simulator")
        }

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Yosemite campground\n")
        let firstResult = app.buttons.matching(identifier: "campgroundResult").firstMatch
        guard firstResult.waitForExistence(timeout: 20) else { throw XCTSkip("Apple Maps returned no campgrounds") }
        let resultCount = app.buttons.matching(identifier: "campgroundResult").count

        firstResult.tap()
        let done = app.buttons["closeCampground"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Details open in a sheet on Duo")
        done.tap()

        XCTAssertTrue(firstResult.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "campgroundResult").count, resultCount, "The results are kept")
        XCTAssertEqual(field.value as? String, "Yosemite campground", "The query is kept")
    }
}
