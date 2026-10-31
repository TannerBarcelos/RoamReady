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

    func testGlobalChatReceivesSavedCurrentTripWithoutAttachmentStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-document-assistant-fixture", "-document-readiness-fixture",
                               "-assistant-ui-test", "ready", "-assistant-generation-test", "saved-trip"]
        app.launch()
        openAssistant(app)
        ask(app, "What trip is this?")
        let reply = app.staticTexts["assistantGeneratedReply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        XCTAssertTrue(reply.label.contains("Current Pines"))
        XCTAssertTrue(app.descendants(matching: .any)["assistantSavedTripSource"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["assistantIncompleteNote"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["assistantReadiness"].exists)
        XCTAssertFalse(app.buttons["assistantSearchedReferences"].exists)
        XCTAssertFalse(app.buttons["assistantSourceRow"].exists)
    }

    func testFoodQuestionsReceiveTheCurrentTripsSavedMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-assistant-ui-test", "ready", "-assistant-generation-test", "saved-menu"]
        app.launch()
        openAssistant(app)
        ask(app, "What’s for dinner?")
        let reply = app.staticTexts["assistantGeneratedReply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        XCTAssertTrue(reply.label.contains("Steak with brussels sprouts and sourdough"), reply.label)
        XCTAssertTrue(app.descendants(matching: .any)["assistantSavedTripSource"].exists)
    }

    func testStepHelpUsesCurrentEditorDraftAndKeepsItForFollowUps() {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-assistant-ui-test", "ready", "-assistant-generation-test", "step-context"]
        app.launch()
        XCTAssertTrue(app.buttons["tripRow-Current Pines"].waitForExistence(timeout: 10))
        app.buttons["tripRow-Current Pines"].tap()
        let checklist = app.descendants(matching: .any)["tripChecklist-teardown"].firstMatch
        for _ in 0..<8 where !checklist.isHittable { app.swipeUp() }
        checklist.tap()
        let details = app.buttons["Details and edit Disconnect and stow shore power"]
        for _ in 0..<12 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        let notes = app.descendants(matching: .any)["checklistStepNotes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Ask about this step"].isHittable, "Step help is visible before scrolling")
        notes.tap()
        notes.typeText("Fixture note: blue cable bag.")
        let guidance = app.descendants(matching: .any)["checklistStepGuidance"].firstMatch
        for _ in 0..<8 where !guidance.isHittable { app.swipeUp() }
        guidance.tap()
        guidance.typeText(" Draft guidance retained.")
        let help = app.buttons["Ask about this step"]
        for _ in 0..<8 where !help.isHittable { app.swipeDown() }
        help.tap()
        XCTAssertTrue(app.buttons["assistantSend"].waitForExistence(timeout: 5))
        app.buttons["assistantSend"].tap()
        let first = app.staticTexts["assistantGeneratedReply"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        for field in ["Disconnect and stow shore power", "Draft guidance retained.", "Fixture note: blue cable bag.", "Pending", "Teardown"] {
            XCTAssertTrue(first.label.contains(field), "The system instructions should include \(field)")
        }
        ask(app, "And then?")
        let followUp = app.staticTexts.matching(identifier: "assistantGeneratedReply").element(boundBy: 1)
        XCTAssertTrue(followUp.waitForExistence(timeout: 15))
        XCTAssertTrue(followUp.label.contains("Fixture note: blue cable bag."))
        XCTAssertTrue(followUp.label.contains("Draft guidance retained."))
        app.buttons["closeAssistant"].tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertFalse((notes.value as? String ?? "").contains("Fixture note:"), "Asking for help does not save the draft")
    }

    func testUnsupportedDeviceHasNoAssistantButton() {
        let app = launch("unsupported")
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["openAssistant"].exists)
    }

    /// Devices that can't run Apple's on-device model have no Assistant anywhere, not even a mention.
    func testUnsupportedDeviceNeverMentionsTheAssistant() {
        let app = XCUIApplication()
        app.launchArguments = ["-assistant-ui-test", "unsupported", "-navigation-ui-test"]
        app.launch()
        XCTAssertTrue(app.navigationTab("Home").waitForExistence(timeout: 10))
        assertNoAssistant(in: app, "Home")

        app.buttons["tripRow-Current Pines"].tap()
        XCTAssertTrue(app.navigationBars["Current Pines"].waitForExistence(timeout: 5))
        for _ in 0..<4 { app.swipeUp() }
        assertNoAssistant(in: app, "Trip details")
        let checklist = app.buttons["tripChecklist-setup"]
        for _ in 0..<4 where !checklist.isHittable { app.swipeDown() }
        checklist.tap()
        XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout: 5))
        for _ in 0..<4 { app.swipeUp() }
        assertNoAssistant(in: app, "Checklist")

        app.navigationTab("Profile").tap()
        app.buttons["openAppSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for _ in 0..<4 { app.swipeUp() }
        assertNoAssistant(in: app, "Settings")
    }

    private func assertNoAssistant(in app: XCUIApplication, _ screen: String) {
        let mentions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Assistant' OR label CONTAINS[c] 'camping help' OR label BEGINSWITH 'Ask about'"))
        XCTAssertEqual(mentions.count, 0, "\(screen) mentions the Assistant: \(mentions.allElementsBoundByIndex.map(\.label))")
    }

    func testAssistantUsesTheNativeToolbarOnEveryDevice() {
        let app = launch("ready")
        XCTAssertTrue(app.barAssistantButton.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "openAssistant").count, 1)
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
        XCTAssertTrue(app.descendants(matching: .any)["assistantSourcePassage"].waitForExistence(timeout: 5), "The source opens as a dialog in the chat")
        app.buttons["openSourceDocument"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["citedPageViewer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
    }

    /// Canned chat from `-document-source-states-fixture`: one answer each for a cited source, a replaced
    /// document, a deleted one, and an uncited answer. Needs no model or index.
    private func launchSourceStates() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-document-assistant-fixture", "-document-source-states-fixture",
                               "-assistant-ui-test", "ready"]
        app.launch()
        openAssistant(app)
        XCTAssertTrue(app.staticTexts["Press the ignition button for ten seconds."].waitForExistence(timeout: 10))
        return app
    }

    /// The transcript opens scrolled to its end, so earlier rows can sit under the toolbar; scroll until the
    /// row is clear of it.
    private func sourceRow(_ app: XCUIApplication, containing title: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: "assistantSourceRow").matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        for _ in 0..<8 where !row.isHittable || row.frame.minY < 260 { app.scrollViews.firstMatch.swipeDown() }
        return row
    }

    func testOnlyUsedSourcesAreShown() {
        let app = launchSourceStates()
        XCTAssertFalse(app.staticTexts["General advice. No document was cited."].exists)
        let cited = sourceRow(app, containing: "Water Heater Manual")
        XCTAssertTrue(cited.exists)
        XCTAssertTrue(cited.label.hasPrefix("Source:"))
        XCTAssertTrue(app.staticTexts["Sources"].exists)
        XCTAssertFalse(app.buttons["assistantSearchedReferences"].exists)
        XCTAssertFalse(app.buttons["assistantSearchedRow"].exists)
    }

    /// A source opens as a dialog over the chat with the passage the answer used; the document is one tap more.
    private func openDocument(from row: XCUIElement, in app: XCUIApplication) {
        row.tap()
        let open = app.buttons["openSourceDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["citedPageViewer"].exists, "Tapping a source doesn't leave the chat")
        open.tap()
    }

    func testCitedSourceOpensAsADialogWithItsPassage() {
        let app = launchSourceStates()
        sourceRow(app, containing: "Water Heater Manual").tap()
        let passage = app.descendants(matching: .any)["assistantSourcePassage"]
        XCTAssertTrue(passage.waitForExistence(timeout: 5))
        XCTAssertTrue(passage.label.contains("igniter failed to light"))
        XCTAssertTrue(app.staticTexts["Cited in this answer"].exists)
    }

    func testCitedSourceOpensAtItsPage() {
        let app = launchSourceStates()
        openDocument(from: sourceRow(app, containing: "Water Heater Manual"), in: app)
        XCTAssertTrue(app.descendants(matching: .any)["citedPageViewer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
    }

    func testReplacedSourceShowsChangedAndOpensTheCurrentFileOnlyOnRequest() {
        let app = launchSourceStates()
        openDocument(from: sourceRow(app, containing: "Furnace Manual"), in: app)
        XCTAssertTrue(app.staticTexts["Changed since this answer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["citedPageViewer"].exists, "The new file is not opened silently")
        app.buttons["openCurrentVersion"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["citedPageViewer"].waitForExistence(timeout: 10))
    }

    func testDeletedSourceShowsNoLongerInYourLibrary() {
        let app = launchSourceStates()
        openDocument(from: sourceRow(app, containing: "Awning Manual"), in: app)
        XCTAssertTrue(app.staticTexts["No longer in your library"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["citedPageViewer"].exists)
        XCTAssertFalse(app.buttons["openCurrentVersion"].exists)
    }

    func testDocumentReadinessStaysOutOfChat() {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-document-assistant-fixture", "-document-readiness-fixture",
                               "-assistant-ui-test", "ready", "-assistant-generation-test", "document"]
        app.launch()
        openAssistant(app)
        XCTAssertTrue(app.descendants(matching: .any)["assistantQuestion"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["assistantReadiness"].exists)
        ask(app, "When was the anode rod replaced?")
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["assistantIncompleteNote"].exists)
        XCTAssertFalse(app.buttons["assistantRetryWithDocuments"].exists)
        XCTAssertFalse(app.buttons["assistantSearchedRow"].exists)
        XCTAssertFalse(app.buttons["assistantSourceRow"].exists)
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

    func testSlowRequestShowsNoStatusText() {
        let app = launch("ready", generation: "slow")
        openAssistant(app)
        ask(app, "How do I keep drinking water clean?")
        let progress = app.descendants(matching: .any)["assistantProgress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["assistantProgress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Thinking…"].exists)
        XCTAssertFalse(app.staticTexts["Searching documents…"].exists)
        XCTAssertFalse(app.staticTexts["Writing an answer…"].exists)
        XCTAssertFalse(app.progressIndicators.matching(NSPredicate(format: "label CONTAINS '%'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        XCTAssertFalse(progress.exists, "Stages disappear once the answer arrives")
    }

    func testClosingTheSheetCancelsTheRequestAndLeavesNoLateReply() {
        let app = launch("ready", generation: "slow")
        openAssistant(app)
        ask(app, "How do I keep drinking water clean?")
        XCTAssertTrue(app.descendants(matching: .any)["assistantProgress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Thinking…"].exists)
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
        XCTAssertTrue(app.descendants(matching: .any)["assistantProgress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Thinking…"].exists)
        app.buttons["closeAssistant"].tap()
        openAssistant(app)
        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        // The canceled question returned to the field; the follow-up text is added to it.
        input.typeText(" Second question")
        app.buttons["assistantSend"].tap()
        XCTAssertTrue(app.staticTexts["assistantGeneratedReply"].waitForExistence(timeout: 10))
        sleep(4)
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantGeneratedReply").count, 1)
        func shown(_ text: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        XCTAssertTrue(shown("Second question"))
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

    /// Regression for a factual trip question drifting into attachment disclaimers and maintenance advice.
    /// Uses the real model with synthetic saved trips and an unfinished attachment.
    func testLiveOnDeviceTripOverviewStaysOnTopic() throws {
        guard ProcessInfo.processInfo.environment["ROAMREADY_RUN_ON_DEVICE_AI_SMOKE"] == "1" else {
            throw XCTSkip("Requires an eligible physical iPhone; enable ROAMREADY_RUN_ON_DEVICE_AI_SMOKE in the Test scheme.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-document-assistant-fixture", "-document-readiness-fixture",
                               "-assistant-device-smoke"]
        app.launch()
        openAssistant(app)
        ask(app, "What trip is this?")
        let reply = app.staticTexts["assistantGeneratedReply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90))
        let answer = reply.label.lowercased()
        XCTAssertTrue(answer.contains("current pines"), "The answer should identify the saved trip")
        for unrelated in ["maintenance", "document", "attachment", "towel", "hose", "first-aid", "flashlight"] {
            XCTAssertFalse(answer.contains(unrelated), "A trip overview must not add \(unrelated): \(reply.label)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["assistantSavedTripSource"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["assistantIncompleteNote"].exists)
        XCTAssertFalse(app.buttons["assistantSourceRow"].exists)
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
