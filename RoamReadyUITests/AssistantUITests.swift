import XCTest

@MainActor
final class AssistantUITests: XCTestCase {
    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", state]
        app.launch()
        return app
    }

    func testUnsupportedDeviceHasNoAssistantTab() {
        let app = launch("unsupported")
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Assistant"].exists)
    }

    func testDisabledAIDisplaysRecoveryInsteadOfConversation() {
        assertUnavailable("disabled", title: "Turn on Apple Intelligence")
    }

    func testPreparingModelDisplaysRecoveryInsteadOfConversation() {
        assertUnavailable("preparing", title: "Apple Intelligence is getting ready")
    }

    func testRuntimeFailureDisplaysRecoveryInsteadOfConversation() {
        assertUnavailable("unavailable", title: "AI is currently unavailable")
    }

    private func assertUnavailable(_ state: String, title: String) {
        let app = launch(state)
        let assistant = app.tabBars.buttons["Assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 10))
        assistant.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(app.otherElements["assistantConversation"].exists)
        XCTAssertFalse(app.textViews["assistantQuestion"].exists)
        XCTAssertFalse(app.textFields["assistantQuestion"].exists)
        XCTAssertFalse(app.buttons["assistantSend"].exists)
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts[title].exists)
    }

    func testReadyChatHasOnlyTextComposerAndSend() {
        let app = launch("ready")
        let assistant = app.tabBars.buttons["Assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 10))
        assistant.tap()
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let send = app.buttons["assistantSend"]
        XCTAssertFalse(send.isEnabled)
        input.tap()
        input.typeText("My refrigerator is warm")
        XCTAssertTrue(send.isEnabled)
        for label in ["Attach", "Add attachment", "Upload file", "Add photo", "Camera"] {
            XCTAssertFalse(app.buttons[label].exists)
        }
    }
}
