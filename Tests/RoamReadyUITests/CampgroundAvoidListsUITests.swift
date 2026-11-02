import XCTest

/// Camp Finder's "Would not go" list, from a fixture campground into Your campgrounds. The library
/// is in memory, so nothing here touches a real one.
@MainActor
final class CampgroundAvoidListsUITests: XCTestCase {
    func testAvoidingACampgroundListsItUnderWouldNotGo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-assistant-ui-test", "ready", "-permissions-ui-test", "allowed",
                               "-weather-ui-test", "-connectivity-ui-test", "online", "-camp-finder-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Camp Finder").waitForExistence(timeout: 10))
        app.navigationTab("Camp Finder").tap()
        let nearby = app.buttons.matching(identifier: "campgroundResult").matching(NSPredicate(format: "label CONTAINS 'Nearby Pines'")).firstMatch
        XCTAssertTrue(nearby.waitForExistence(timeout: 15))
        nearby.tap()
        let toggle = app.switches["Would not go"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The details offer the list")
        XCTAssertTrue(app.switches["Would not return"].exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter().wait(for: [on], timeout: 5), .completed, "The list switch turns on")

        app.buttons["closeCampground"].tap()
        app.buttons["Your campgrounds"].tap()
        XCTAssertTrue(app.navigationBars["Your campgrounds"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Would not go"].exists, "The list has a section")
        // An Apple Maps place keeps only its identifier, so the row may read "Saved campground" until it is looked up.
        let row = app.staticTexts.matching(NSPredicate(format: "label IN {'Nearby Pines', 'Saved campground'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The campground is on it")
        XCTAssertFalse(app.staticTexts["Add campgrounds to avoid from Camp Finder."].exists, "Would not go is not empty")
        XCTAssertTrue(app.staticTexts["Mark places you wouldn’t go back to from Camp Finder."].exists, "Would not return is empty")
    }
}
