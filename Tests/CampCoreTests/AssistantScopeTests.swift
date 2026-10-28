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

    private let turns: [ScopedChatTurn<String>] = [
        ScopedChatTurn(scope: "rigA", question: "What is E4 on the water heater?", answer: "Igniter failure."),
        ScopedChatTurn(scope: "rigB", question: "What is the tire pressure?", answer: "65 psi."),
        ScopedChatTurn(scope: "rigA", question: "How long do I wait?", answer: "Five minutes.")
    ]

    func testOnlyTheCurrentScopesTurnsReachThePrompt() {
        let history = AssistantConversationRules.history(turns, in: "rigA")
        XCTAssertEqual(history.map(\.question), ["What is E4 on the water heater?", "How long do I wait?"])
        let other = AssistantConversationRules.history(turns, in: "rigB")
        XCTAssertEqual(other.map(\.answer), ["65 psi."])
        XCTAssertTrue(AssistantConversationRules.history(turns, in: "trip").isEmpty)
    }

    func testAPromptForANewScopeCarriesNoPriorScopeText() {
        let history = AssistantConversationRules.history(turns, in: "rigC")
        let request = CampingHelpRequest(question: "Where is the fuse box?", steps: [], rigType: nil, step: nil,
                                         scope: .general, history: history)
        for leaked in ["E4", "65 psi", "Igniter", "tire pressure"] {
            XCTAssertFalse(request.prompt.contains(leaked), leaked)
            XCTAssertFalse(request.compactPrompt.contains(leaked), leaked)
        }
    }

    func testFollowUpRetrievalUsesUserQuestionsOnly() {
        let history = AssistantConversationRules.history(turns, in: "rigA")
        let query = AssistantConversationRules.retrievalQuestion("And then?", after: history)
        XCTAssertTrue(query.contains("How long do I wait?"))
        XCTAssertTrue(query.contains("And then?"))
        XCTAssertFalse(query.contains("Five minutes"))
        XCTAssertFalse(query.contains("Igniter"))
        XCTAssertEqual(AssistantConversationRules.retrievalQuestion("E4?", after: []), "E4?")
    }

    func testEarlierGeneratedTextCannotBecomeACitableSource() {
        let history = [CampingChatTurn(question: "What is E4?", answer: "It is the igniter [S1]. See also [S2, S3].")]
        let evidence = DocumentEvidence(excerpts: [])
        let request = CampingHelpRequest(question: "And the fix?", steps: [], rigType: nil, step: nil, scope: .general,
                                         history: history, documents: evidence)
        XCTAssertFalse(request.prompt.contains("[S1]"))
        XCTAssertFalse(request.prompt.contains("[S2"))
        // Whatever a model repeats from earlier text resolves against this request's manifest, which is empty.
        let resolved = DocumentCitations.resolve("Same as before [S1].", manifest: evidence.manifest(compact: false))
        XCTAssertTrue(resolved.sources.isEmpty)
        XCTAssertEqual(resolved.droppedCount, 1)
    }
}
