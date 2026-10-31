import Foundation
import Testing
@testable import CampCore

/// Stands in for a model with tool calling: records what it was offered and optionally "calls" `get_trip`.
@MainActor
private final class ToolGenerator: CampingResponseGenerating {
    var offered: [CampingTools?] = []
    var calls: CampingToolCall?

    func respond(to prompt: String, instructions: String) async throws -> String { "Plain answer." }

    func respond(to prompt: String, instructions: String, tools: CampingTools?) async throws -> CampingSessionReply {
        offered.append(tools)
        guard let calls, let tools else { return CampingSessionReply(text: "Plain answer.") }
        return CampingSessionReply(text: "Answer from \(tools.output(for: calls).count) characters.", toolsUsed: [calls.kind])
    }
}

/// A session that records the tool turn each request offered.
@MainActor
private final class ToolTurnModel: CampingChatModel {
    var turns: [CampingToolTurn?] = []
    var histories: [[CampingChatTurn]] = []
    var replies: [CampingSessionReply] = []

    func makeSession(history: [CampingChatTurn]) -> any CampingChatSession { Session(model: self) }
    func summarize(_ turns: [CampingChatTurn], into summary: String?) async throws -> String { "summary" }

    private final class Session: CampingChatSession {
        unowned let model: ToolTurnModel
        init(model: ToolTurnModel) { self.model = model }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String { "answer" }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                     toolTurn: CampingToolTurn?) async throws -> CampingSessionReply {
            model.turns.append(toolTurn)
            model.histories.append(history)
            return model.replies.isEmpty ? CampingSessionReply(text: "answer") : model.replies.removeFirst()
        }
        func store(_ turn: CampingChatTurn) {}
        func remove(_ turnID: CampingChatTurn.ID) {}
    }
}

@MainActor
struct CampingToolsTests {
    private let trip: TripDraft = {
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        var trip = TripDraft(campgroundName: "Pinecrest Lake", arrival: arrival, departure: arrival.addingTimeInterval(86_400),
                             planningTimeZoneIdentifier: "America/Denver")
        trip.siteNumber = "A-203"; trip.bookingProvider = "Recreation.gov"; trip.totalCost = 84
        return trip
    }()

    private var tools: CampingTools {
        CampingTools(
            trip: TripToolFacts(trip, notes: "Shady pad near the creek",
                                checklist: TripChecklistFacts(setup: [ChecklistStepDraft(title: "Chock wheels", status: .completed),
                                                                      ChecklistStepDraft(title: "Level the trailer", notes: "Use blocks", priority: .high)],
                                                              teardown: []),
                                now: trip.arrival.addingTimeInterval(-3 * 86_400)),
            menu: TripMenuFacts(days: [.init(number: 1, label: "Day 1", meals: [
                .init(kind: .dinner, title: "Dinner", dishes: [.init(name: "Chili", notes: "", items: [.init(name: "Beans", quantity: "2 cans")])])
            ])]))
    }

    private let rig = CampingRigContext(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5))

    private func request(_ question: String, tools: CampingTools?, step: ChecklistStepDraft? = nil) -> CampingHelpRequest {
        CampingHelpRequest(question: question, steps: [], rigType: .travelTrailer, step: step, scope: .checklist,
                           rigContext: rig, tools: tools)
    }

    @Test func tripQuestionsOfferGetTripAndCarryTheRigInTheInstructions() {
        let turn = request("What am I making tonight?", tools: tools)
        #expect(turn.tools == tools)
        #expect(turn.instructions.contains(CampingToolKind.trip.name))
        #expect(!turn.instructions.contains("you must call it at least once"))
        #expect(turn.instructions.contains("BEGIN SAVED RIG PROFILE"), "The rig is rebuilt into the instructions every turn")
        #expect(turn.instructions.contains("Manufacturer: \"Forest River\""))
        #expect(!turn.prompt.contains(TripBookingFacts.beginMarker), "Trip data arrives only through get_trip")
        #expect(!turn.usesSavedTrip, "Offering the tool isn't using the trip")
    }

    @Test func overviewsAndStepHelpStillOfferGetTrip() {
        let overview = request("What trip is this?", tools: tools)
        #expect(overview.isTripOverview && overview.tools == tools)
        #expect(overview.instructions.contains("supplied for this turn by \(CampingToolKind.trip.name)"))
        #expect(!overview.instructions.contains("BEGIN SAVED RIG PROFILE"), "An overview needs only the trip")
        let step = request("What's for dinner?", tools: tools, step: ChecklistStepDraft(title: "Level the trailer"))
        #expect(step.tools == tools, "A step question can still need the trip")
    }

    @Test func chatWithoutATripOffersNoToolAndSaysSo() {
        let general = request("Will 30 amp run my AC?", tools: nil)
        #expect(general.tools == nil)
        #expect(!general.instructions.contains(CampingToolKind.trip.name))
        #expect(general.instructions.contains("No trip is selected"))
        #expect(general.instructions.contains("BEGIN SAVED RIG PROFILE"), "The rig still helps without a trip")
    }

    @Test func everyFocusCarriesTheCoreFactsPlusItsSection() {
        for focus in TripFocus.allCases {
            let output = tools.output(for: CampingToolCall(focus: focus))
            #expect(output.hasPrefix(TripBookingFacts.beginMarker) && output.hasSuffix(TripBookingFacts.endMarker), "\(focus)")
            #expect(output.contains("Campground: \"Pinecrest Lake\""), "\(focus)")
            #expect(output.contains("Site: \"A-203\""), "\(focus)")
            #expect(output.contains("Status: starts in 3 days"), "\(focus)")
        }
        let overview = tools.output(for: CampingToolCall(focus: .overview))
        #expect(!overview.contains("Checklists:") && !overview.contains("Menu:") && !overview.contains("Booked through"))

        let booking = tools.output(for: CampingToolCall(focus: .booking))
        #expect(booking.contains("Booked through: \"Recreation.gov\"") && booking.contains("Total cost: 84.00"))
        #expect(booking.contains("Site notes: \"Shady pad near the creek\""))
        #expect(!booking.contains("Chili"))

        let checklist = tools.output(for: CampingToolCall(focus: .checklist))
        #expect(checklist.contains("Setup: 1 of 2 finished."))
        #expect(checklist.contains("- [to do] \"Level the trailer\" priority: high notes: \"Use blocks\""))
        #expect(checklist.contains("Chock wheels") && checklist.contains("Teardown"))

        let dinner = tools.output(for: CampingToolCall(focus: .menu))
        #expect(dinner.contains("\"Chili\"") && dinner.contains("\"Beans\", amount: \"2 cans\""))

        let everything = tools.output(for: CampingToolCall(focus: .everything))
        for part in ["Booked through", "Setup: 1 of 2 finished.", "\"Chili\""] { #expect(everything.contains(part), "\(part)") }
    }

    @Test func theChatGivesTheToolTheRoomThePromptAndHistoryLeave() async throws {
        let model = ToolTurnModel()
        let chat = CampingChat(model: model, counter: ConservativeTokenEstimator())
        let turn = request("What's for dinner?", tools: tools)
        _ = try await chat.answer(turn)
        let plan = try await turn.plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        let offered = try #require(model.turns.first ?? nil)
        #expect(offered.tools == tools)
        #expect(offered.availableTokens == PromptBudget().inputLimit - plan.usage.total)
        #expect(offered.question == "What's for dinner?")
        #expect(offered.availableTokens >= tools.outputReserveTokens)

        _ = try await chat.answer(request("Will 30 amp run my AC?", tools: nil))
        #expect(model.turns.last == .some(nil), "No trip, no tool")
    }

    @Test func theToolDefinitionIsCountedInThePlan() async throws {
        let plain = try await request("What's for dinner?", tools: nil).plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        let offered = try await request("What's for dinner?", tools: tools).plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        #expect(offered.usage.tools == CampingTools.schemaTokensPerTool)
        #expect(plain.usage.tools == 0)
        #expect(offered.usage.total <= PromptBudget().inputLimit)
    }

    @Test func resourceRetrievalDoesNotTruncateLongBookingNotesOrChecklists() {
        let notes = String(repeating: "Booking details ", count: 300) + "Booking ending."
        let steps = (1...50).map { ChecklistStepDraft(title: "Step \($0)", notes: String(repeating: "Follow this detail. ", count: 15) + "Step ending.") }
        let complete = CampingTools(trip: TripToolFacts(trip, notes: notes, checklist: TripChecklistFacts(setup: steps, teardown: steps)),
                                    menu: tools.menu)
        let output = complete.output(for: CampingToolCall(focus: .everything))
        #expect(output.contains("Booking ending."))
        #expect(output.components(separatedBy: "Step ending.").count - 1 == 100)
        #expect(output.contains("Chili") && output.contains("Beans"))
    }

    @Test func aTripLookupMakesTheSavedTripASource() async throws {
        let generator = ToolGenerator()
        generator.calls = CampingToolCall(focus: .menu)
        let reply = try await CampingGeneration.answer(to: request("What am I making tonight?", tools: tools), using: generator)
        #expect(reply.usedSavedTrip)
        #expect(generator.offered.first ?? nil == tools)

        let plain = try await CampingGeneration.answer(to: request("How do I level the trailer?", tools: tools), using: ToolGenerator())
        #expect(!plain.usedSavedTrip, "No call, no saved-trip source")
    }

    /// Verifies the chat plumbing accepts a model's choice to answer directly after a lookup.
    /// Actual tool selection and cooking-answer quality still need an on-device model evaluation.
    @Test func cookingFollowUpKeepsContextAndAllowsNoLookup() async throws {
        let model = ToolTurnModel()
        model.replies = [CampingSessionReply(text: "Dinner is NY strip steak.", toolsUsed: [.trip]),
                         CampingSessionReply(text: "Pat the steak dry, season it, and sear it in a hot skillet.")]
        let chat = CampingChat(model: model)
        let menu = try await chat.answer(request("What are we eating on this trip?", tools: tools))
        let cooking = try await chat.answer(request("How should I cook the steak? What's the best way?", tools: tools))

        #expect(menu.usedSavedTrip)
        #expect(!cooking.usedSavedTrip, "A direct answer has no saved-trip source")
        #expect(model.turns.count == 2 && model.turns.allSatisfy { $0?.tools == tools },
                "The tool stays available; the app does not classify or hide it for the follow-up")
        let history = try #require(model.histories.last)
        #expect(history.count == 1 && history.first?.answer == menu.text,
                "The model can resolve the steak from the previous answer")
        #expect(chat.turns.last?.answer == cooking.text)
    }
}
