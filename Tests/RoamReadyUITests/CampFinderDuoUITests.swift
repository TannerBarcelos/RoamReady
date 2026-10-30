import XCTest

/// Camp Finder follows real width traits. A regular-width window (Duo's open display, or an
/// iPad simulator) arranges the results and map in separate panes; a compact one keeps the
/// stacked list. No search runs, so the test doesn't depend on Apple Maps results.
@MainActor
final class CampFinderDuoUITests: XCTestCase {
    func testDuoCampFinderPlacesResultsForTheAvailableWidth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-layout-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Camp Finder").waitForExistence(timeout: 10))
        app.navigationTab("Camp Finder").tap()
        XCTAssertTrue(app.navigationBars["Camp Finder"].waitForExistence(timeout: 5))
        if app.staticTexts["Connection needed"].exists {
            throw XCTSkip("Camp Finder needs a network connection on this simulator")
        }

        let results = app.descendants(matching: .any)["campFinderResults"].firstMatch
        let map = app.descendants(matching: .any)["campFinderMap"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Near me"].exists)
        XCTAssertTrue(app.searchFields.firstMatch.exists, "The search field stays visible in both layouts")

        let window = app.windows.firstMatch
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Camp Finder (\(window.horizontalSizeClass == .regular ? "regular" : "compact") width)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if window.horizontalSizeClass == .regular {
            // A split arrangement can divide horizontally or vertically, and balances the panes
            // around the fold. Neither a fixed column width nor a larger map pane is guaranteed.
            let beside = map.frame.minX >= results.frame.maxX - 1 || results.frame.minX >= map.frame.maxX - 1
            let stacked = map.frame.minY >= results.frame.maxY - 1 || results.frame.minY >= map.frame.maxY - 1
            XCTAssertTrue(beside || stacked, "The map and results occupy separate arrangement panes")
            if window.frame.width > window.frame.height {
                XCTAssertTrue(beside, "The open landscape display places results beside the map")
            }
            let searchField = app.searchFields.firstMatch
            XCTAssertGreaterThanOrEqual(searchField.frame.minX, results.frame.minX - 1)
            XCTAssertLessThanOrEqual(searchField.frame.maxX, results.frame.maxX + 1,
                                     "Search stays inside the results column instead of crossing the map")
            XCTAssertFalse(searchField.frame.intersects(map.frame), "Search must not overlay the map")
            XCTAssertGreaterThan(map.frame.width, 0)
            XCTAssertGreaterThan(map.frame.height, 0)
            XCTAssertTrue(map.isHittable, "The map stays interactive in its pane")
        } else {
            XCTAssertLessThanOrEqual(map.frame.maxY, app.buttons["Near me"].frame.minY, "The map stays above the results")
            XCTAssertGreaterThanOrEqual(map.frame.minX, results.frame.minX)
            XCTAssertLessThanOrEqual(map.frame.maxX, results.frame.maxX)
        }
    }
}
