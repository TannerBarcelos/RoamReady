import XCTest

@MainActor
final class NavigationUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        return app
    }

    func testHomeKeepsOverlappingAndUpcomingTripsWithoutPlanTab() {
        let app = launch()
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        XCTAssertFalse(app.tabBars.buttons["Plan"].exists)
        XCTAssertTrue(app.staticTexts["Current Pines"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Overlapping Creek"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Upcoming Lake"].exists)
        XCTAssertFalse(app.staticTexts["Past Meadows"].exists)
        app.staticTexts["Upcoming Lake"].tap()
        XCTAssertTrue(app.navigationBars["Upcoming Lake"].waitForExistence(timeout: 5))
    }

    func testProfileOwnsTripHistoryAndCampgrounds() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.buttons["tripHistoryLink"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["savedCampgroundsLink"].exists)
        XCTAssertFalse(app.segmentedControls["appearancePicker"].exists)
        XCTAssertFalse(app.buttons["prepareLibraryExport"].exists)
        app.buttons["tripHistoryLink"].tap()
        XCTAssertTrue(app.navigationBars["Trip history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Past Meadows"].exists)
        XCTAssertFalse(app.staticTexts["Upcoming Lake"].exists)
        app.staticTexts["Past Meadows"].tap()
        XCTAssertTrue(app.navigationBars["Past Meadows"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["savedCampgroundsLink"].tap()
        XCTAssertTrue(app.navigationBars["Your campgrounds"].waitForExistence(timeout: 5))
    }

    func testSettingsContainsAppearanceAndLibraryTools() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
        app.buttons["openAppSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["appearancePicker"].exists)
        let export = app.buttons["prepareLibraryExport"]
        for _ in 0..<4 {
            if export.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(export.isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
    }

    func testAddTripStillPresentsFromProfileAndReturnsToIt() {
        let app = launch()
        app.tabBars.buttons["Profile"].tap()
        app.tabBars.buttons["Trip"].tap()
        XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Profile"].isSelected)
    }
}
