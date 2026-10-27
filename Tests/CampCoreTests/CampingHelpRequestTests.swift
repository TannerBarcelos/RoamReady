import XCTest
@testable import CampCore

final class CampingHelpRequestTests: XCTestCase {
    func testQuestionsWithoutAReferenceMatchStillReachTheModel() {
        let general = CampingHelpRequest(question: "Why is my refrigerator warm?", steps: [], rigType: nil,
                                         step: nil, scope: .general)
        XCTAssertTrue(general.passages.isEmpty)
        XCTAssertTrue(general.prompt.contains("Why is my refrigerator warm?"))
        let checklist = CampingHelpRequest(question: "Why is my refrigerator warm?", steps: [], rigType: nil,
                                           step: nil, scope: .checklist)
        XCTAssertTrue(checklist.passages.isEmpty)
        XCTAssertTrue(checklist.prompt.contains("Why is my refrigerator warm?"))
        XCTAssertTrue(checklist.instructions.contains("general camping knowledge"),
                      "Trip help answers beyond saved notes instead of refusing")
    }

    func testHazardsAreHandledByTheModelWithSafetyFirstInstructions() {
        let request = CampingHelpRequest(question: "I smell gas", steps: [], rigType: nil, step: nil, scope: .checklist)
        XCTAssertTrue(request.instructions.contains("emergency services"))
    }

    func testFollowUpRetainsTopicAndSelectedStepTakesPriority() {
        let water = ChecklistStepDraft(title: "Fresh water", detail: "Check the supply setting")
        let power = ChecklistStepDraft(title: "Shore power", detail: "Use rated equipment")
        let request = CampingHelpRequest(question: "What should I check next?", steps: [water, power],
                                        rigType: .travelTrailer, step: nil, scope: .general,
                                        history: [CampingChatTurn(question: "The water stopped", answer: "Check the supply")])
        XCTAssertTrue(request.passages.contains(water.detail))
        XCTAssertFalse(request.passages.contains(power.detail))
        XCTAssertTrue(request.prompt.contains("The water stopped"))
        XCTAssertTrue(request.prompt.contains("Check the supply"))
        let selected = CampingHelpRequest(question: "water", steps: [water, power], rigType: nil,
                                         step: power, scope: .checklist)
        XCTAssertEqual(selected.passages, "Shore power: Use rated equipment")
    }

    func testOwnerNotesAreMatchedAndSentAsReference() {
        let hose = ChecklistStepDraft(title: "Connect drinking water", detail: "Use a potable-water hose",
                                      notes: "Regulator lives in the curbside bay")
        let power = ChecklistStepDraft(title: "Shore power", detail: "Use rated equipment")
        let request = CampingHelpRequest(question: "Where did I put the regulator?", steps: [hose, power],
                                        rigType: .travelTrailer, step: nil, scope: .checklist)
        XCTAssertEqual(request.passages, "Connect drinking water: Use a potable-water hose\nMy notes: Regulator lives in the curbside bay",
                       "Notes alone can match the question")
        let blank = ChecklistStepDraft(title: "Shore power", detail: "Use rated equipment", notes: "  \n ")
        XCTAssertEqual(CampingHelpRequest(question: "power", steps: [], rigType: nil, step: blank, scope: .checklist).passages,
                       "Shore power: Use rated equipment", "Blank notes add nothing")
    }

    func testLongConversationsUseBoundedRecentContext() {
        let history = [CampingChatTurn(question: "Old topic", answer: "Old answer")]
            + (1...3).map { CampingChatTurn(question: "Recent \($0) " + String(repeating: "q", count: 5000),
                                           answer: String(repeating: "a", count: 5000)) }
        let request = CampingHelpRequest(question: String(repeating: "x", count: 5000), steps: [],
                                        rigType: nil, step: nil, scope: .general, history: history)
        XCTAssertFalse(request.prompt.contains("Old topic"))
        XCTAssertTrue(request.prompt.contains("Recent 3"))
        XCTAssertLessThan(request.prompt.count, 6500, "Keep context within the on-device model's budget")
    }
}
