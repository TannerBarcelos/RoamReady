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

    /// Regular iPhones keep the floating button; only iPad, Mac, Duo, and accessibility sizes use the toolbar.
    func testIPhoneKeepsTheFloatingAssistantButton() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPad uses the toolbar") }
        let app = launch("ready")
        XCTAssertTrue(app.buttons["openAssistant"].waitForExistence(timeout: 10))
        if app.descendants(matching: .any)["duoWorkspace"].exists { throw XCTSkip("Duo uses the toolbar") }
        XCTAssertFalse(app.barAssistantButton.exists, "The floating button stays out of the bars")
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

    /// The transcript opens scrolled to its end, so earlier rows can sit under the scope banner; scroll until
    /// the row is clear of the banner.
    private func sourceRow(_ app: XCUIApplication, containing title: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: "assistantSourceRow").matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        for _ in 0..<8 where !row.isHittable || row.frame.minY < 260 { app.scrollViews.firstMatch.swipeDown() }
        return row
    }

    func testCitedSourcesAndSearchedReferencesAreLabeledApart() {
        let app = launchSourceStates()
        // The newest answer is on screen first: uncited, so it explains why instead of listing sources.
        XCTAssertTrue(app.staticTexts["General advice. No document was cited."].exists, "An uncited answer says why")
        let cited = sourceRow(app, containing: "Water Heater Manual")
        XCTAssertTrue(cited.exists)
        XCTAssertTrue(cited.label.hasPrefix("Source:"))
        XCTAssertTrue(app.staticTexts["Sources"].exists)
        let searched = app.buttons.matching(identifier: "assistantSearchedRow").firstMatch
        XCTAssertTrue(searched.exists)
        XCTAssertTrue(searched.label.hasPrefix("Searched, not cited:"), "VoiceOver hears that it was only searched")
        XCTAssertTrue(app.staticTexts["References searched"].exists)
        XCTAssertTrue(app.staticTexts["Looked at, but not cited in this answer."].exists, "Never described as used")
    }

    func testCitedSourceOpensAtItsPage() {
        let app = launchSourceStates()
        let cited = sourceRow(app, containing: "Water Heater Manual")
        cited.tap()
        XCTAssertTrue(app.descendants(matching: .any)["citedPageViewer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Page 2"].exists)
    }

    func testReplacedSourceShowsChangedAndOpensTheCurrentFileOnlyOnRequest() {
        let app = launchSourceStates()
        let furnace = sourceRow(app, containing: "Furnace Manual")
        furnace.tap()
        XCTAssertTrue(app.staticTexts["Changed since this answer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["citedPageViewer"].exists, "The new file is not opened silently")
        app.buttons["openCurrentVersion"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["citedPageViewer"].waitForExistence(timeout: 10))
    }

    func testDeletedSourceShowsNoLongerInYourLibrary() {
        let app = launchSourceStates()
        sourceRow(app, containing: "Awning Manual").tap()
        XCTAssertTrue(app.staticTexts["No longer in your library"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["citedPageViewer"].exists)
        XCTAssertFalse(app.buttons["openCurrentVersion"].exists)
    }

    /// A ready manual and a scan that is still being read (held by the fixture until "Finish test scan"). Chat
    /// answers from the manual and says coverage was incomplete; a question that needs the scan says it can't
    /// yet support an answer. When the scan finishes, Retry appears under the earlier answers, nothing is
    /// submitted by itself, and tapping it asks again while keeping the earlier answer.
    func testReadyManualPlusUnfinishedScanNotesIncompleteCoverageAndOffersRetryWhenReady() {
        let app = XCUIApplication()
        app.launchArguments = ["-navigation-ui-test", "-document-assistant-fixture", "-document-readiness-fixture",
                               "-assistant-ui-test", "ready", "-assistant-generation-test", "document"]
        app.launch()
        openAssistant(app)
        let summary = app.descendants(matching: .any)["assistantReadiness"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS '1 of 2 documents ready'"), evaluatedWith: summary)
        waitForExpectations(timeout: 30)

        let input = app.descendants(matching: .any)["assistantQuestion"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        // The transcript is lazy and scrolls to the newest message, so look things up by what they say.
        func element(_ identifier: String, containing text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier)
                .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        func ask(_ question: String) {
            input.tap()
            input.typeText(question)
            app.buttons["assistantSend"].tap()
        }
        // Swipes the transcript itself, not the sheet, which a swipe from the top edge would dismiss.
        func scrollTranscript(until target: XCUIElement) {
            for _ in 0..<12 where !target.exists { app.scrollViews.firstMatch.swipeDown() }
        }

        // Needs the scan: nothing relevant is ready, so the answer can't yet support it and cites nothing.
        ask("When was the anode rod replaced?")
        XCTAssertTrue(element("assistantGeneratedReply", containing: "isn't ready yet").waitForExistence(timeout: 15))
        XCTAssertTrue(element("assistantIncompleteNote", containing: "can’t yet support").waitForExistence(timeout: 5))
        XCTAssertTrue(element("assistantIncompleteNote", containing: "Scanned Service Record (being read)").exists)
        XCTAssertEqual(app.buttons.matching(identifier: "assistantSourceRow").count, 0, "No document facts are cited")

        // Answerable from the ready manual: answered, with an incomplete-coverage note.
        ask("What does fault code E4 mean on my water heater?")
        XCTAssertTrue(element("assistantSourceRow", containing: "Water Heater Manual").waitForExistence(timeout: 15))
        XCTAssertTrue(element("assistantIncompleteNote", containing: "Not every document was searched").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["assistantRetryWithDocuments"].exists, "No retry while the scan is unfinished")

        // The scan finishes. Retry is offered, but nothing is asked on its own.
        let repliesBefore = app.staticTexts.matching(identifier: "assistantGeneratedReply").count
        app.buttons["releaseTestScan"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'All 2 documents ready'"), evaluatedWith: summary)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(app.buttons["assistantRetryWithDocuments"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantGeneratedReply").count, repliesBefore, "Nothing is submitted automatically")
        XCTAssertEqual(app.buttons.matching(identifier: "assistantSourceRow").matching(NSPredicate(format: "label CONTAINS 'Scanned'")).count, 0)

        // Retry the first question: a new answer from the scan, and the earlier answer stays.
        let firstAnswer = element("assistantGeneratedReply", containing: "isn't ready yet")
        scrollTranscript(until: firstAnswer)
        let retry = app.buttons["assistantRetryWithDocuments"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(element("assistantSourceRow", containing: "Scanned Service Record").waitForExistence(timeout: 15))
        // The retry only appends; the earlier answer is never replaced.
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "assistantGeneratedReply").count, 1)
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
