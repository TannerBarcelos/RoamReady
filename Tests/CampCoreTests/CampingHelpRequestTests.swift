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

    func testRoutineTankCleaningDoesNotReceiveAnEvacuationScript() {
        let rig = RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5)
        let template = ChecklistFactory.template(for: rig)
        let request = CampingHelpRequest(question: "How do I clean the black water tank after flushing on my RV?",
                                        steps: template.setup + template.teardown, rigType: rig.type,
                                        step: nil, scope: .general)
        XCTAssertFalse(request.instructions.contains("move everyone away from the rig"),
                       "A routine request must not carry a canned evacuation script into generation")
        XCTAssertTrue(request.instructions.contains("routine maintenance"))
    }

    func testSavedRigDetailsReachTheInitialInstructionsWithoutRegistrationOrPhotos() {
        let rig = RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024,
                           floorplan: "19.8", photo: Data("private photo".utf8),
                           equipment: Equipment(slideOuts: true), lengthFeet: 23,
                           slideCount: 1, axleCount: 2, hasBunkhouse: true,
                           vin: "1HGCM82633A004352", licensePlate: "PRIVATE123", plateRegion: "SECRETREGION")
        let request = CampingHelpRequest(question: "What rig and equipment do I have?", steps: [], rigType: rig.type,
                                        step: nil, scope: .general, rigContext: CampingRigContext(rig))
        let inputs = request.instructions + request.prompt + request.compactPrompt
        for fact in ["Forest River", "No Boundaries", "2024", "Floorplan code: \"19.8\"", "Overall length: 23 ft", "Slide-out count: 1",
                     "Axle count: 2", "Bunkhouse: Yes", "Wastewater connection selected: Yes", "Propane selected: Yes"] {
            XCTAssertTrue(request.instructions.contains(fact), "Initial model instructions must contain \(fact)")
        }
        for privateValue in [rig.vin, rig.licensePlate, rig.plateRegion, "private photo"] {
            XCTAssertFalse(inputs.contains(privateValue))
        }
    }

    func testRigContextIsBoundedAndAbsentValuesAreNotInvented() {
        let rig = RigDraft(type: .tent, make: String(repeating: "x", count: 5000), equipment: .none,
                           lengthFeet: .infinity)
        let request = CampingHelpRequest(question: "What do I have?", steps: [], rigType: nil,
                                        step: nil, scope: .general, rigContext: CampingRigContext(rig))
        XCTAssertTrue(request.prompt.contains("Rig category: Tent"))
        XCTAssertFalse(request.instructions.contains(String(repeating: "x", count: 101)))
        XCTAssertFalse(request.instructions.contains("Model year:"))
        XCTAssertFalse(request.instructions.contains("Overall length:"))
        XCTAssertTrue(request.instructions.contains("Wastewater connection selected: No"))
        XCTAssertLessThan(request.instructions.count, 2500)
    }

    func testFollowUpRetainsTopicAndSelectedStepTakesPriority() {
        let water = ChecklistStepDraft(title: "Fresh water", detail: "Check the supply setting")
        let power = ChecklistStepDraft(title: "Shore power", detail: "Use rated equipment")
        let request = CampingHelpRequest(question: "What should I check next?", steps: [water, power],
                                        rigType: .travelTrailer, step: nil, scope: .general,
                                        previousQuestion: "The water stopped")
        XCTAssertTrue(request.passages.contains(water.detail))
        XCTAssertFalse(request.passages.contains(power.detail))
        XCTAssertFalse(request.prompt.contains("The water stopped"), "the session carries earlier turns, not the prompt")
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

    func testLongQuestionsAreBounded() {
        let request = CampingHelpRequest(question: String(repeating: "x", count: 5000), steps: [],
                                        rigType: nil, step: nil, scope: .general)
        XCTAssertLessThan(request.prompt.count, 2000, "Keep context within the on-device model's budget")
        XCTAssertTrue(request.questionExceedsLimit)
    }

    func testStoredTurnsAreClippedAndNeutralized() {
        let turn = CampingChatTurn(question: String(repeating: "q", count: 5000), answer: String(repeating: "a", count: 5000) + " [S1]")
        XCTAssertEqual(turn.question.count, CampingChatTurn.questionCharacters)
        XCTAssertEqual(turn.answer.count, CampingChatTurn.answerCharacters)
        let marked = CampingChatTurn(question: "What is E4?", answer: "Igniter [S1].")
        XCTAssertEqual(marked.answer, "Igniter (S1).")
    }
}
