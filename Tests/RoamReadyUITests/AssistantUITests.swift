import XCTest

@MainActor
final class AssistantUITests: XCTestCase {
    private func launch(_ state: String, generation: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", state]
        if let generation { app.launchArguments += ["-assistant-generation-test", generation] }
        app.launch()
        return app
    }

    func testUnsupportedDeviceHasNoAssistantButton() {
        let app = launch("unsupported")
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openAssistant"].exists)
    }

    func testTabBarFitsWithoutMore() {
        let app = launch("ready")
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        XCTAssertFalse(app.tabBars.buttons["Plan"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profile"].exists, "Profile must not be pushed into a More tab")
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
    }

    func testAssistantIsReachableFromEveryTab() {
        let app = launch("ready")
        for tab in ["Home", "Plan", "Camp Finder", "Profile"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            openAssistant(app)
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
        }
    }

    func testTripActionPresentsSheetAndPreservesSelectedTab() {
        let app = launch("unsupported")
        let plan = app.tabBars.buttons["Plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10))
        plan.tap()
        app.tabBars.buttons["Trip"].tap()
        XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Cannot save a booking without a rig and campground")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(plan.isSelected)
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

    func testUnsupportedLanguageDisplaysRecoveryInsteadOfConversation() {
        assertUnavailable("unsupported-language", title: "This language isn’t supported")
    }

    func testSendDisplaysGeneratedResponse() {
        let app = launch("ready", generation: "reply")
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("How do I keep drinking water clean?")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Couldn’t get a response"].exists)
    }

    func testConversationSurvivesClosingTheAssistant() {
        let app = launch("ready", generation: "reply")
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("How do I keep drinking water clean?")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        app.buttons["closeAssistant"].tap()
        openAssistant(app)
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 5), "Reopening keeps the chat")
    }

    func testModelFailureRestoresQuestionAndNeverShowsAnAIAnswer() {
        let app = launch("ready", generation: "failure")
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("How do I keep drinking water clean?")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t get a response"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["assistantGeneratedReply"].exists)
        XCTAssertEqual(input.value as? String, "How do I keep drinking water clean?")
        XCTAssertTrue(app.buttons["assistantSend"].isEnabled)
    }

    /// Opt in via the scheme's Test environment on an actual eligible iPhone, with its model ready.
    /// This path never sets simulated availability or generation flags.
    func testLiveOnDeviceFoundationModelsResponseAndFollowUp() throws {
        guard ProcessInfo.processInfo.environment["ROAMREADY_RUN_ON_DEVICE_AI_SMOKE"] == "1" else {
            throw XCTSkip("Requires an eligible physical iPhone; enable ROAMREADY_RUN_ON_DEVICE_AI_SMOKE in the Test scheme.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-device-smoke"]
        app.launch()
        let button = app.buttons["openAssistant"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Physical iPhone must support Apple Intelligence")
        button.tap()
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Enable Apple Intelligence and finish the model download first")
        input.tap()
        input.typeText("What are two ways to keep drinking water clean while camping?")
        app.buttons["assistantSend"].tap()
        let reply = app.staticTexts["assistantGeneratedReply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "Must get a real model response, not saved guidance")
        XCTAssertFalse(reply.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        input.tap()
        input.typeText("Can you explain the first suggestion?")
        app.buttons["assistantSend"].tap()
        let secondReply = app.staticTexts.matching(identifier: "assistantGeneratedReply").element(boundBy: 1)
        XCTAssertTrue(secondReply.waitForExistence(timeout: 90))
    }

    private func openAssistant(_ app: XCUIApplication) {
        let button = app.buttons["openAssistant"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func assertUnavailable(_ state: String, title: String) {
        let app = launch(state)
        openAssistant(app)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(app.textViews["assistantQuestion"].exists)
        XCTAssertFalse(app.textFields["assistantQuestion"].exists)
        XCTAssertFalse(app.buttons["assistantSend"].exists)
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts[title].exists)
    }

    func testReadyChatHasOnlyTextComposerAndSend() {
        let app = launch("ready")
        openAssistant(app)
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
