import XCTest
@testable import CampCore

final class AssistantScopeTests: XCTestCase {
    func testSummaryNamesTheRigOrTheTripAndItsRig() {
        XCTAssertEqual(AssistantScopeSummary(rigName: "Forest River No Boundaries").text, "Rig: Forest River No Boundaries")
        XCTAssertEqual(AssistantScopeSummary(rigName: "Forest River No Boundaries", tripName: "Pines").text,
                       "Trip: Pines · Rig: Forest River No Boundaries")
        XCTAssertEqual(AssistantScopeSummary(rigName: "Old Rig", tripName: "Pines", rigIsArchived: true).text,
                       "Trip: Pines · Rig: Old Rig (archived)")
        XCTAssertEqual(AssistantScopeSummary(rigName: nil).text, "No active rig")
        XCTAssertEqual(AssistantScopeSummary(rigName: nil, tripName: "Pines").text, "Trip: Pines · Rig unavailable")
    }

    func testFollowUpRetrievalUsesUserQuestionsOnly() {
        let query = AssistantConversationRules.retrievalQuestion("And then?", after: "How long do I wait?")
        XCTAssertEqual(query, "How long do I wait? And then?")
        XCTAssertEqual(AssistantConversationRules.retrievalQuestion("E4?", after: nil), "E4?")
    }

    func testStepFollowUpRetrievalKeepsTheSelectedStepTopic() {
        XCTAssertEqual(AssistantConversationRules.retrievalQuestion("And then?", after: "What do I do first?",
                                                                   stepTitle: "Disconnect shore power"),
                       "Disconnect shore power What do I do first? And then?")
    }

    func testAPromptCarriesNoEarlierTurns() {
        let request = CampingHelpRequest(question: "Where is the fuse box?", steps: [], rigType: nil, step: nil,
                                         scope: .general, previousQuestion: "What is the tire pressure?")
        for leaked in ["tire pressure", "CONVERSATION"] {
            XCTAssertFalse(request.prompt.contains(leaked), leaked)
            XCTAssertFalse(request.compactPrompt.contains(leaked), leaked)
        }
    }

    func testEarlierGeneratedTextCannotBecomeACitableSource() {
        let stored = CampingChatTurn(question: "What is E4?", answer: "It is the igniter [S1]. See also [S2, S3].")
        XCTAssertFalse(stored.answer.contains("[S1]"))
        XCTAssertFalse(stored.answer.contains("[S2"))
        // Whatever a model repeats from earlier text resolves against this request's manifest, which is empty.
        let evidence = DocumentEvidence(excerpts: [])
        let resolved = DocumentCitations.resolve("Same as before [S1].", manifest: evidence.manifest(compact: false))
        XCTAssertTrue(resolved.sources.isEmpty)
        XCTAssertEqual(resolved.droppedCount, 1)
    }
}
