import XCTest
@testable import CampCore

final class ChecklistStepDraftTests: XCTestCase {
    func testPriorityMarksFollowReminders() {
        XCTAssertEqual(ChecklistPriority.allCases, [.none, .low, .medium, .high])
        XCTAssertEqual(ChecklistPriority.allCases.map(\.marks), ["", "!", "!!", "!!!"])
        XCTAssertEqual(ChecklistPriority.allCases.map(\.title), ["None", "Low", "Medium", "High"])
    }

    func testNewAndGeneratedStepsHaveNoPriorityOrNotes() {
        let step = ChecklistStepDraft(title: "Fill the kettle")
        XCTAssertEqual(step.priority, ChecklistPriority.none)
        XCTAssertEqual(step.notes, "")
        XCTAssertNil(step.visibleNotes)
        let template = ChecklistFactory.template(for: RigDraft(type: .travelTrailer))
        XCTAssertTrue((template.setup + template.teardown).allSatisfy { $0.priority == ChecklistPriority.none && $0.notes.isEmpty },
                      "Generated guidance goes in detail, never in the owner's notes")
    }

    func testEqualityComparesNotesAndPriorityButNotIdentity() {
        let step = ChecklistStepDraft(title: "Check tire pressure", notes: "Cold reading: 80 psi", priority: .high)
        var copy = step; copy.id = UUID()
        XCTAssertEqual(step, copy, "Copies get fresh identities")
        var renoted = step; renoted.notes = "Cold reading: 65 psi"
        XCTAssertNotEqual(step, renoted)
        var reprioritized = step; reprioritized.priority = .low
        XCTAssertNotEqual(step, reprioritized)
    }

    func testVisibleNotesTrimBlankLines() {
        XCTAssertNil(ChecklistStepDraft(title: "Step", notes: " \n\t ").visibleNotes)
        XCTAssertEqual(ChecklistStepDraft(title: "Step", notes: "\nLeft bay, under the hose\n").visibleNotes, "Left bay, under the hose")
    }

    func testPriorityAndNotesSurviveEncoding() throws {
        let template = ChecklistTemplate(setup: [ChecklistStepDraft(title: "Chock the wheels", notes: "Chocks in the front bin", priority: .medium)])
        let decoded = try JSONDecoder().decode(ChecklistTemplate.self, from: JSONEncoder().encode(template))
        XCTAssertEqual(decoded, template)
        XCTAssertEqual(decoded.setup.first?.priority, .medium)
        XCTAssertEqual(try JSONDecoder().decode(ChecklistPriority.self, from: Data(#""high""#.utf8)), .high)
    }
}
