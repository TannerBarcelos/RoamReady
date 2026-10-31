import Foundation
import Testing
@testable import CampCore

/// Stands in for a model with tool calling: records what it was offered and optionally "calls" a tool.
@MainActor
private final class ToolGenerator: CampingResponseGenerating {
    var offered: [CampingTools?] = []
    var instructions: [String] = []
    var calls: CampingToolKind?

    func respond(to prompt: String, instructions: String) async throws -> String { "Plain answer." }

    func respond(to prompt: String, instructions: String, tools: CampingTools?) async throws -> CampingSessionReply {
        offered.append(tools)
        self.instructions.append(instructions)
        guard let calls, let tools else { return CampingSessionReply(text: "Plain answer.") }
        let output = calls == .tripMenu ? tools.menuOutput(day: 1, meal: .dinner) : tools.checklistOutput(phase: .setup, remainingOnly: true)
        return CampingSessionReply(text: "Answer from \(output.count) characters.", toolsUsed: [calls])
    }
}

@MainActor
struct CampingToolsTests {
    private let trip: TripDraft = {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        return TripDraft(campgroundName: "Pinecrest Lake", arrival: arrival, departure: arrival.addingTimeInterval(86_400),
                         planningTimeZoneIdentifier: "America/Denver")
    }()

    private var tools: CampingTools {
        CampingTools(
            menu: TripMenuFacts(days: [.init(number: 1, label: "Day 1", meals: [
                .init(kind: .dinner, title: "Dinner", dishes: [.init(name: "Chili", notes: "", items: [.init(name: "Beans", quantity: "2 cans")])])
            ])]),
            checklist: TripChecklistFacts(setup: [ChecklistStepDraft(title: "Chock wheels", status: .completed),
                                                  ChecklistStepDraft(title: "Level the trailer", notes: "Use blocks", priority: .high)],
                                          teardown: []))
    }

    private func request(_ question: String, tools: CampingTools?, step: ChecklistStepDraft? = nil) -> CampingHelpRequest {
        CampingHelpRequest(question: question, steps: [], rigType: nil, step: step, scope: .checklist,
                           tripFacts: TripBookingFacts(trip), tools: tools)
    }

    @Test func tripQuestionsOfferTheToolsAndNameThemInTheInstructions() {
        let turn = request("What am I making tonight?", tools: tools)
        #expect(turn.tools == tools)
        #expect(turn.instructions.contains(CampingToolKind.tripMenu.name))
        #expect(turn.instructions.contains(CampingToolKind.tripChecklist.name))
        #expect(!turn.prompt.contains(TripMenuFacts.beginMarker), "Trip data reaches the model only through the tools")
        #expect(!turn.usesSavedTrip, "Offering a tool isn't using the trip")
    }

    @Test func overviewsStepHelpAndEmptyToolboxesOfferNoTools() {
        #expect(request("What trip is this?", tools: tools).tools == nil)
        #expect(request("What's next?", tools: tools, step: ChecklistStepDraft(title: "Level the trailer")).tools == nil)
        let none = request("What's for dinner?", tools: CampingTools())
        #expect(none.tools == nil)
        #expect(!none.instructions.contains(CampingToolKind.tripMenu.name))
        let menuOnly = request("What's for dinner?", tools: CampingTools(menu: tools.menu))
        #expect(menuOnly.instructions.contains(CampingToolKind.tripMenu.name))
        #expect(!menuOnly.instructions.contains(CampingToolKind.tripChecklist.name))
    }

    @Test func theChecklistToolReportsProgressAndRemainingSteps() {
        let all = tools.checklistOutput(phase: .setup, remainingOnly: false)
        #expect(all.contains("Setup: 1 of 2 finished."))
        #expect(all.contains("- [done] \"Chock wheels\""))
        #expect(all.contains("- [to do] \"Level the trailer\" priority: high notes: \"Use blocks\""))
        let remaining = tools.checklistOutput(phase: .setup, remainingOnly: true)
        #expect(!remaining.contains("Chock wheels") && remaining.contains("Level the trailer"))
        #expect(tools.checklistOutput(phase: nil, remainingOnly: false).contains("Teardown: 0 of 0 finished."))
        #expect(CampingTools().checklistOutput(phase: nil, remainingOnly: false) == "This trip has no checklist.")
    }

    @Test func toolDefinitionsAreCountedAndAResultIsReservedFromHistory() async throws {
        let plain = try await request("What's for dinner?", tools: nil).plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        let offered = try await request("What's for dinner?", tools: tools).plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        #expect(offered.usage.tools == 2 * CampingTools.schemaTokensPerTool)
        #expect(plain.usage.tools == 0)
        #expect(offered.usage.total > plain.usage.total + offered.usage.tools - 1)
        #expect(offered.usage.total <= PromptBudget().inputLimit)
        #expect(tools.outputReserveTokens >= CampingTools.outputCharacters / ConservativeTokenEstimator.asciiCharactersPerToken)
        #expect(CampingTools().outputReserveTokens == 0)
    }

    @Test func aToolCallMakesTheSavedTripASource() async throws {
        let generator = ToolGenerator()
        generator.calls = .tripMenu
        let reply = try await CampingGeneration.answer(to: request("What am I making tonight?", tools: tools), using: generator)
        #expect(reply.usedSavedTrip)
        #expect(generator.offered.first??.menu == tools.menu)

        let quiet = ToolGenerator()
        let plain = try await CampingGeneration.answer(to: request("How do I level the trailer?", tools: tools), using: quiet)
        #expect(!plain.usedSavedTrip, "No call, no saved-trip source")
        #expect(quiet.offered.first??.checklist == tools.checklist)
    }
}
