import XCTest

/// Home beside the selected trip on Duo (#84). `-duo-ui-test` forces the workspace, so this runs
/// on any simulator: side by side on a regular-width display, collapsed on the Duo cover display.
@MainActor
final class DuoHomeUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-duo-ui-test"] + extra
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    private func detailTrip(_ app: XCUIApplication) -> String {
        let marker = app.descendants(matching: .any)["homeDetailTrip"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        return marker.label
    }

    /// Back to Home when the split view is collapsed; side by side Home never left.
    private func showHome(_ app: XCUIApplication) {
        // The Duo cover display moves bar buttons into a side rail, outside the navigation bar.
        if !app.staticTexts["Hello, Riley"].isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Hello, Riley"].waitForExistence(timeout: 5))
    }

    func testCurrentTripIsSelectedAndPickingAnotherReplacesIt() {
        let app = launch()
        // "Current Pines" and "Overlapping Creek" overlap today; Home features the earlier arrival.
        XCTAssertEqual(detailTrip(app), "Current Pines")
        XCTAssertTrue(app.staticTexts["Hello, Riley"].exists, "Home stays in front or beside the trip")

        app.buttons["tripRow-Current Pines"].tap()
        XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))

        showHome(app)
        let later = app.buttons["tripRow-Upcoming Lake"]
        for _ in 0..<4 where !later.isHittable { app.swipeUp() }
        later.tap()
        XCTAssertTrue(app.navigationBars["Upcoming Lake"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Current Pines"].exists, "The picked trip replaces the detail")
        XCTAssertEqual(detailTrip(app), "Upcoming Lake")
    }

    func testChecklistShortcutsOpenTheRightPhaseBesideHome() {
        let app = launch()
        XCTAssertEqual(checklist(app), "None")
        app.buttons["Teardown checklist"].tap()
        XCTAssertTrue(app.navigationBars["Teardown"].waitForExistence(timeout: 5))
        XCTAssertEqual(checklist(app), "Teardown")
        XCTAssertEqual(detailTrip(app), "Current Pines")

        showHome(app)
        app.buttons["Continue setup"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 5))
        XCTAssertEqual(checklist(app), "Setup")
    }

    /// Home keeps the shown phase above the checklist, so a fold that rebuilds the columns keeps it.
    func testSwitchingThePhaseInsideTheChecklistUpdatesHomesPick() {
        let app = launch()
        app.buttons["Teardown checklist"].tap()
        XCTAssertTrue(app.navigationBars["Teardown"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Setup"].tap()
        XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 5))
        XCTAssertEqual(checklist(app), "Setup", "Home's pick follows the checklist's phase")

        showHome(app)
        app.buttons["Teardown checklist"].tap()
        XCTAssertTrue(app.navigationBars["Teardown"].waitForExistence(timeout: 5), "A shortcut switches an open checklist")
        XCTAssertEqual(checklist(app), "Teardown")
    }

    func testDeletingTheSelectedTripFallsBackToTheFeaturedTrip() {
        let app = launch()
        app.buttons["Teardown checklist"].tap()
        XCTAssertEqual(checklist(app), "Teardown")
        showHome(app)
        app.buttons["tripRow-Current Pines"].tap()
        XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))
        app.buttons["Trip options"].firstMatch.tap()
        app.buttons["Cancel & delete trip"].firstMatch.tap()
        app.alerts.buttons["Delete Trip"].tap()

        XCTAssertTrue(app.staticTexts["Hello, Riley"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tripRow-Current Pines"].exists)
        XCTAssertEqual(detailTrip(app), "Overlapping Creek", "The detail falls back to the next featured trip")
        XCTAssertEqual(checklist(app), "None", "The deleted trip's checklist pick is cleared")
    }

    private func checklist(_ app: XCUIApplication) -> String {
        let marker = app.descendants(matching: .any)["homeDetailChecklist"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        return marker.label
    }

    func testEmptyLibraryKeepsCreateActionsAndAQuietDetail() {
        let app = launch(["-empty-library"])
        XCTAssertEqual(detailTrip(app), "None")
        XCTAssertTrue(app.buttons["Find a campground"].exists)
        app.buttons["Add a trip"].tap()
        XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Add a trip"].waitForExistence(timeout: 5))
    }
}
