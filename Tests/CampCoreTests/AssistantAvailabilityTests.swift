import XCTest
@testable import CampCore

final class AssistantAvailabilityTests: XCTestCase {
    func testOnlyReadyAIShowsConversationAndComposer() {
        XCTAssertTrue(AssistantAvailability.ready.showsTab)
        XCTAssertTrue(AssistantAvailability.ready.showsConversation)
        for state in [AssistantAvailability.disabled, .preparing, .unavailable, .unsupportedLanguage] {
            XCTAssertTrue(state.showsTab, "Supported devices retain the tab to explain setup/failure")
            XCTAssertFalse(state.showsConversation, "Show the unavailable screen instead of chat or its composer")
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.message.isEmpty)
        }
        XCTAssertFalse(AssistantAvailability.unsupported.showsTab)
        XCTAssertFalse(AssistantAvailability.unsupported.showsConversation)
    }

    func testDisabledAndPreparingStatesExplainHowToRecover() {
        XCTAssertEqual(AssistantAvailability.disabled.title, "Turn on Apple Intelligence")
        XCTAssertTrue(AssistantAvailability.disabled.message.contains("Settings"))
        XCTAssertTrue(AssistantAvailability.preparing.message.contains("downloading or preparing"))
        XCTAssertNotEqual(AssistantAvailability.disabled.message, AssistantAvailability.preparing.message)
    }

    func testEnablingAIReplacesTheErrorPresentationAndDisablingItRestoresIt() {
        var state = AssistantAvailability.disabled
        XCTAssertFalse(state.showsConversation)
        state = .preparing
        XCTAssertFalse(state.showsConversation)
        state = .ready
        XCTAssertTrue(state.showsConversation)
        state = .disabled
        XCTAssertFalse(state.showsConversation)
    }
}
