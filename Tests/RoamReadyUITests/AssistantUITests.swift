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
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openAssistant"].exists)
    }

    func testTabBarFitsWithoutMore() {
        let app = launch("ready")
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationTab("Profile").exists, "Profile must not be pushed into a More tab")
        XCTAssertFalse(app.navigationTab("Plan").exists)
        XCTAssertFalse(app.navigationTab("More").exists)
    }

    func testAssistantIsReachableFromEveryTab() {
        let app = launch("ready")
        for tab in ["Home", "Camp Finder", "Profile"] {
            let button = app.navigationTab(tab)
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            openAssistant(app)
            XCTAssertTrue(app.buttons["closeAssistant"].waitForExistence(timeout: 5))
            app.buttons["closeAssistant"].tap()
        }
    }

    func testTripActionPresentsSheetAndPreservesSelectedTab() {
        let app = launch("unsupported")
        let profile = app.navigationTab("Profile")
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        app.navigationTab("Trip").tap()
        XCTAssertTrue(app.navigationBars["Add trip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Cannot save a booking without a rig and campground")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(profile.isSelected)
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

    /// Import → index → ask → cited source → PDF at the cited page, using the fixture's synthetic manual and a
    /// stubbed model that cites it. Indexing runs in the background, so the question is retried until the
    /// manual is ready.
    func testAnswerCitesTheManualAndTheSourceOpensAtTheCitedPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-document-assistant-fixture", "-assistant-ui-test", "ready",
                               "-assistant-generation-test", "document"]
        app.launch()
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let source = app.buttons["assistantSourceRow"].firstMatch
        for _ in 0..<6 where !source.exists {
            input.tap()
            input.typeText("What does fault code E4 mean on my water heater?")
            app.buttons["assistantSend"].tap()
            _ = source.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(source.exists, "A validated source row appears under the answer")
        XCTAssertEqual(app.buttons.matching(identifier: "assistantSourceRow").count, 1, "Another rig's manual is never cited")
        XCTAssertTrue(source.label.contains("Water Heater Manual"))
        XCTAssertTrue(source.label.contains("Page 2"))
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["citedPageViewer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
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

    func testSlowRequestShowsOnlyStagesThatHappened() {
        let app = launch("ready", generation: "slow")
        openAssistant(app)
        ask(app, "How do I keep drinking water clean?")
        let progress = app.descendants(matching: .any)["assistantProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Writing an answer…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Thinking…"].exists)
        XCTAssertFalse(app.progressIndicators.matching(NSPredicate(format: "label CONTAINS '%'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        XCTAssertFalse(progress.exists, "Stages disappear once the answer arrives")
    }

    func testClosingTheSheetCancelsTheRequestAndLeavesNoLateReply() {
        let app = launch("ready", generation: "slow")
        openAssistant(app)
        ask(app, "How do I keep drinking water clean?")
        XCTAssertTrue(app.staticTexts["Writing an answer…"].waitForExistence(timeout: 5))
        app.buttons["closeAssistant"].tap()
        sleep(5)
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["assistantGeneratedReply"].exists, "A canceled request never adds a reply")
        XCTAssertFalse(app.descendants(matching: .any)["assistantProgress"].exists)
        XCTAssertEqual(input.value as? String, "How do I keep drinking water clean?", "The question returns to the field")
    }

    func testSecondQuestionIsNotOverwrittenByTheCanceledFirst() {
        let app = launch("ready", generation: "slow")
        openAssistant(app)
        ask(app, "First question")
        XCTAssertTrue(app.staticTexts["Writing an answer…"].waitForExistence(timeout: 5))
        app.buttons["closeAssistant"].tap()
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "First question".count))
        input.typeText("Second question")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        sleep(4)
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantGeneratedReply").count, 1)
        XCTAssertTrue(app.staticTexts["You: Second question"].exists || app.otherElements["You: Second question"].exists)
        XCTAssertFalse(app.staticTexts["You: First question"].exists || app.otherElements["You: First question"].exists)
    }

    func testRetryResubmitsTheSameQuestion() {
        let app = launch("ready", generation: "failure-once")
        openAssistant(app)
        ask(app, "How do I keep drinking water clean?")
        let retry = app.buttons["assistantRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Couldn’t get a response"].exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Couldn’t get a response"].exists)
        XCTAssertFalse(retry.exists)
    }

    private func ask(_ app: XCUIApplication, _ text: String) {
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(text)
        app.buttons["assistantSend"].tap()
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
