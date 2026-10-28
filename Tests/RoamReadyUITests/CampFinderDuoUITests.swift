import XCTest

/// Camp Finder under the forced Duo workspace. A regular-width window (Duo's open display, or an
/// iPad simulator) puts the results beside the map; a compact one (Duo's cover display) keeps the
/// stacked list. No search runs, so the test doesn't depend on Apple Maps results.
@MainActor
final class CampFinderDuoUITests: XCTestCase {
    func testDuoCampFinderPlacesResultsForTheAvailableWidth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-duo-ui-test"]
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
            XCTAssertGreaterThanOrEqual(map.frame.minX, results.frame.maxX - 1, "The map sits beside the results")
            XCTAssertGreaterThan(map.frame.width, results.frame.width, "The map takes the larger share")
            XCTAssertGreaterThan(map.frame.height, window.frame.height / 2, "The map fills the content area's height")
        } else {
            XCTAssertLessThanOrEqual(map.frame.maxY, app.buttons["Near me"].frame.minY, "The map stays above the results")
            XCTAssertGreaterThanOrEqual(map.frame.minX, results.frame.minX)
            XCTAssertLessThanOrEqual(map.frame.maxX, results.frame.maxX)
        }
    }
}
