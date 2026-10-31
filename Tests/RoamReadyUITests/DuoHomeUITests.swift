import XCTest

/// Home uses native adaptive navigation on every device: side by side at regular width,
/// collapsed at compact width. The layout-test flag only supplies media fixtures.
@MainActor
final class DuoHomeUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-layout-ui-test"] + extra
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
        if app.windows.firstMatch.horizontalSizeClass == .compact {
            for _ in 0..<3 where !app.navigationBars["Home"].isHittable {
                app.buttons["BackButton"].firstMatch.tap()
            }
        }
        let home = app.descendants(matching: .any)["homeTripList"].firstMatch
        for _ in 0..<4 where !app.staticTexts["Hello, Riley"].isHittable { home.swipeDown() }
        XCTAssertTrue(app.staticTexts["Hello, Riley"].isHittable)
    }

    func testEveryHomeTripShortcutHasBackNavigationToTripDetails() {
        let app = launch()
        for (shortcut, title) in [("homeMenu", "Menu"), ("homeChecklist-setup", "Setup"),
                                  ("homeChecklist-teardown", "Teardown"), ("homeMemories", "Photos & site notes")] {
            let button = app.buttons[shortcut]
            let home = app.descendants(matching: .any)["homeTripList"].firstMatch
            for _ in 0..<6 where !button.isHittable { home.swipeUp() }
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let back = app.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(title) needs a native back button")
            back.tap()
            XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5),
                          "Back from \(title) returns to trip details")
            XCTAssertTrue(app.buttons["tripChecklist-setup"].exists)
            showHome(app)
        }
    }

    func testSelectedTripRowAlwaysReturnsFromItsPagesAndNestedPhotos() throws {
        let app = launch()
        guard app.windows.firstMatch.horizontalSizeClass == .regular else {
            throw XCTSkip("Reselecting a trip alongside its detail requires an expanded window")
        }
        let trip = app.buttons["tripRow-Current Pines"]
        trip.tap()
        for (identifier, title) in [("tripMemories", "Photos & site notes"), ("tripDocuments", "Confirmation & documents"), ("tripMenu", "Menu"),
                                   ("tripChecklist-setup", "Setup"), ("tripChecklist-teardown", "Teardown")] {
            let page = app.buttons[identifier]
            let details = app.descendants(matching: .any)["tripDetailsList"].firstMatch
            for _ in 0..<5 where !app.buttons["tripChecklist-setup"].isHittable { details.swipeDown() }
            for _ in 0..<8 where !page.isHittable { details.swipeUp() }
            XCTAssertTrue(page.isHittable)
            page.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            if identifier == "tripMemories" {
                app.buttons["Earlier note versions"].tap()
                XCTAssertTrue(app.navigationBars["Note history"].waitForExistence(timeout: 5))
            } else if identifier == "tripMenu" {
                let dinner = app.buttons["menuMeal-1-dinner"]
                let menu = app.descendants(matching: .any)["tripMenuList"].firstMatch
                for _ in 0..<6 where !dinner.isHittable { menu.swipeUp() }
                dinner.tap()
                XCTAssertTrue(app.navigationBars["Dinner"].waitForExistence(timeout: 5))
            }
            XCTAssertTrue(trip.isEnabled && trip.isHittable)
            trip.tap()
            XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars[title].exists)
            XCTAssertFalse(app.navigationBars["Note history"].exists)
            XCTAssertFalse(app.navigationBars["Dinner"].exists)
        }
    }

    func testCurrentTripIsSelectedAndPickingAnotherReplacesIt() {
        let app = launch()
        // "Current Pines" and "Overlapping Creek" overlap today; Home features the earlier arrival.
        XCTAssertEqual(detailTrip(app), "Current Pines")
        XCTAssertTrue(app.staticTexts["Hello, Riley"].exists, "Home stays in front or beside the trip")
        XCTAssertFalse(app.staticTexts["Your trip"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue setup'")).firstMatch.exists)

        app.buttons["tripRow-Current Pines"].tap()
        XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))

        showHome(app)
        let later = app.buttons["tripRow-Upcoming Lake"]
        for _ in 0..<4 where !later.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Later trips"].exists)
        later.tap()
        XCTAssertTrue(app.navigationBars["Upcoming Lake"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Current Pines"].exists, "The picked trip replaces the detail")
        XCTAssertEqual(detailTrip(app), "Upcoming Lake")
    }

    func testChecklistShortcutsOpenTheRightPhaseBesideHome() {
        let app = launch()
        XCTAssertEqual(checklist(app), "None")
        app.buttons["homeChecklist-teardown"].tap()
        XCTAssertTrue(app.navigationBars["Teardown"].waitForExistence(timeout: 5))
        XCTAssertEqual(checklist(app), "Teardown")
        XCTAssertEqual(detailTrip(app), "Current Pines")

        showHome(app)
        app.buttons["homeChecklist-setup"].tap()
        XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 5))
        XCTAssertEqual(checklist(app), "Setup")
    }

    /// Home keeps the shown phase above the checklist, so a fold that rebuilds the columns keeps it.
    func testSwitchingThePhaseInsideTheChecklistUpdatesHomesPick() {
        let app = launch()
        app.buttons["homeChecklist-teardown"].tap()
        XCTAssertTrue(app.navigationBars["Teardown"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Setup"].tap()
        XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 5))
        XCTAssertEqual(checklist(app), "Setup", "Home's pick follows the checklist's phase")

        showHome(app)
        app.buttons["homeChecklist-teardown"].tap()
        XCTAssertTrue(app.navigationBars["Teardown"].waitForExistence(timeout: 5), "A shortcut switches an open checklist")
        XCTAssertEqual(checklist(app), "Teardown")
    }

    func testDeletingTheSelectedTripFallsBackToTheFeaturedTrip() {
        let app = launch()
        app.buttons["homeChecklist-teardown"].tap()
        XCTAssertEqual(checklist(app), "Teardown")
        showHome(app)
        app.buttons["tripRow-Current Pines"].tap()
        XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))
        let delete = app.buttons["deleteTrip"]
        for _ in 0..<12 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        delete.tap()
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
        let coverPicker = app.buttons["tripCoverPhotoPicker"]
        for _ in 0..<3 where !coverPicker.isHittable { app.swipeUp() }
        XCTAssertTrue(coverPicker.isHittable, "An optional cover can be uploaded while creating the trip")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Add a trip"].waitForExistence(timeout: 5))
    }
}
