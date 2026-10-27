import XCTest

/// `-duo-ui-test` forces the iPhone Duo workspace so this runs on any simulator.
@MainActor
final class DuoWorkspaceUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-duo-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    func testForcedDuoWorkspaceKeepsTabsSheetsAndSelection() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["duoWorkspace"].waitForExistence(timeout: 5),
                      "The debug argument must turn on the Duo workspace")
        for title in ["Home", "Trip", "Camp Finder", "Profile"] {
            XCTAssertTrue(app.navigationTab(title).exists, "Missing the \(title) tab")
        }
        XCTAssertTrue(app.staticTexts["Current Pines"].exists)

        app.navigationTab("Profile").tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        app.navigationTab("Trip").tap()
        XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationTab("Profile").isSelected, "Add trip returns to the tab it was opened from")

        let assistant = app.buttons["openAssistant"].firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        assistant.tap()
        XCTAssertTrue(app.buttons["closeAssistant"].waitForExistence(timeout: 5))
        app.buttons["closeAssistant"].tap()
        XCTAssertTrue(app.navigationTab("Profile").isSelected, "Closing Assistant keeps the selected tab")
    }
}
