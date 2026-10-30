import XCTest

/// These resize regressions use real layout traits on any simulator. The flag adds fixtures only.
@MainActor
final class DuoWorkspaceUITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(generation: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "ready", "-navigation-ui-test", "-layout-ui-test"]
        if let generation { app.launchArguments += ["-assistant-generation-test", generation] }
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        return app
    }

    func testAdaptiveWorkspaceKeepsTabsSheetsAndSelection() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["homeDetailTrip"].waitForExistence(timeout: 5),
                      "Home uses the same adaptive navigation container on every device")
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

    func testAssistantOpensFromTheToolbarOnEveryTab() {
        let app = launch()
        for tab in ["Home", "Camp Finder", "Profile"] {
            app.navigationTab(tab).tap()
            let toolbarButton = app.barAssistantButton
            XCTAssertTrue(toolbarButton.waitForExistence(timeout: 5), "Assistant belongs in the \(tab) toolbar")
            XCTAssertEqual(app.buttons.matching(identifier: "openAssistant").count, 1, "There is one system toolbar action")
            toolbarButton.tap()
            XCTAssertTrue(app.buttons["closeAssistant"].waitForExistence(timeout: 5))
            app.buttons["closeAssistant"].tap()
        }
    }

    /// The reply is generated while the device rotates; the sheet stays up and the reply arrives.
    func testGeneratingReplySurvivesARotation() {
        let app = launch(generation: "slow-reply")
        let toolbarButton = app.barAssistantButton
        XCTAssertTrue(toolbarButton.waitForExistence(timeout: 5))
        toolbarButton.tap()
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("How do I keep drinking water clean?")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistantProgress"].firstMatch.waitForExistence(timeout: 3))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10),
                      "A reply in progress must finish after a resize")
        XCTAssertTrue(app.buttons["closeAssistant"].exists, "The Assistant stays open through a resize")
        XCTAssertFalse(app.staticTexts["Couldn’t get a response"].exists)
    }

    func testNewTripDraftSurvivesRotationAndReturnsToItsTab() {
        let app = launch()
        app.navigationTab("Profile").tap()
        app.navigationTab("Trip").tap()
        let name = app.textFields["tripCampgroundName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Draft beside the lake")

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, "Draft beside the lake", "Resizing must keep the unsaved draft")
        }

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationTab("Profile").isSelected)
    }
}
