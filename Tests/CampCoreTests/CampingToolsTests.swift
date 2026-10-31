import Foundation
import Testing
@testable import CampCore

/// Stands in for a model with tool calling: records what it was offered and optionally "calls" a tool.
@MainActor
private final class ToolGenerator: CampingResponseGenerating {
    var offered: [CampingTools?] = []
    var calls: CampingToolKind?

    func respond(to prompt: String, instructions: String) async throws -> String { "Plain answer." }

    func respond(to prompt: String, instructions: String, tools: CampingTools?) async throws -> CampingSessionReply {
        offered.append(tools)
        guard let calls, let tools else { return CampingSessionReply(text: "Plain answer.") }
        let output = switch calls {
        case .menu: tools.menuOutput(day: 1, meal: .dinner)
        case .trip: tools.tripOutput(phase: .setup, remainingOnly: true)
        case .rig: tools.rigOutput()
        }
        return CampingSessionReply(text: "Answer from \(output.count) characters.", toolsUsed: [calls])
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
            menu: TripMenuFacts(days: [.init(number: 1, label: "Day 1", meals: [
                .init(kind: .dinner, title: "Dinner", dishes: [.init(name: "Chili", notes: "", items: [.init(name: "Beans", quantity: "2 cans")])])
            ])]),
            trip: TripToolFacts(trip, notes: "Shady pad near the creek",
                                checklist: TripChecklistFacts(setup: [ChecklistStepDraft(title: "Chock wheels", status: .completed),
                                                                      ChecklistStepDraft(title: "Level the trailer", notes: "Use blocks", priority: .high)],
                                                              teardown: []),
                                now: trip.arrival.addingTimeInterval(-3 * 86_400)),
            rig: CampingRigContext(RigDraft(type: .travelTrailer, make: "Forest River", model: "No Boundaries", year: 2024, lengthFeet: 19.5)))
    }

    private func request(_ question: String, tools: CampingTools?, step: ChecklistStepDraft? = nil) -> CampingHelpRequest {
        CampingHelpRequest(question: question, steps: [], rigType: .travelTrailer, step: step, scope: .checklist, tools: tools)
    }

    @Test func tripQuestionsOfferEveryToolAndCarryNoSavedDataInThePrompt() {
        let turn = request("What am I making tonight?", tools: tools)
        #expect(turn.tools?.kinds == [.menu, .trip, .rig])
        #expect(turn.tools?.required == nil, "The model decides")
        for kind in CampingToolKind.allCases { #expect(turn.instructions.contains(kind.name)) }
        #expect(!turn.prompt.contains(TripBookingFacts.beginMarker))
        #expect(!turn.prompt.contains(TripMenuFacts.beginMarker))
        #expect(!turn.instructions.contains("BEGIN SAVED RIG PROFILE"))
        #expect(turn.prompt.contains("Rig category: Travel trailer"), "Only the rig category stays")
        #expect(!turn.usesSavedTrip, "Offering a tool isn't using the trip")
    }

    @Test func anOverviewMustCallTheTripToolAndGetsNothingElse() {
        let overview = request("What trip is this?", tools: tools)
        #expect(overview.isTripOverview)
        #expect(overview.tools?.kinds == [.trip])
        #expect(overview.tools?.required == .trip)
        #expect(overview.instructions.contains("supplied for this turn by \(CampingToolKind.trip.name)"))
    }

    @Test func stepHelpAndGeneralChatOfferOnlyTheRig() {
        let step = request("What's next?", tools: tools, step: ChecklistStepDraft(title: "Level the trailer"))
        #expect(step.tools?.kinds == [.rig])
        let general = request("Will 30 amp run my AC?", tools: CampingTools(rig: tools.rig))
        #expect(general.tools?.kinds == [.rig])
        #expect(!general.instructions.contains(CampingToolKind.trip.name))
        #expect(request("Anything?", tools: CampingTools()).tools == nil)
        #expect(CampingTools(required: .trip).required == nil, "A tool that isn't offered can't be required")
    }

    @Test func theTripToolReturnsBookingDetailsNotesAndChecklistProgress() {
        let all = tools.tripOutput(phase: nil, remainingOnly: false)
        #expect(all.hasPrefix(TripBookingFacts.beginMarker) && all.hasSuffix(TripBookingFacts.endMarker))
        #expect(all.contains("Campground: \"Pinecrest Lake\""))
        #expect(all.contains("Site: \"A-203\""))
        #expect(all.contains("Status: starts in 3 days"))
        #expect(all.contains("Booked through: \"Recreation.gov\""))
        #expect(all.contains("Total cost: 84.00"))
        #expect(all.contains("Site notes: \"Shady pad near the creek\""))
        #expect(all.contains("Setup: 1 of 2 finished."))
        #expect(all.contains("- [to do] \"Level the trailer\" priority: high notes: \"Use blocks\""))
        #expect(all.contains("Teardown: 0 of 0 finished."))
        let remaining = tools.tripOutput(phase: .setup, remainingOnly: true)
        #expect(!remaining.contains("Chock wheels") && remaining.contains("Level the trailer") && !remaining.contains("Teardown"))
        #expect(CampingTools().tripOutput(phase: nil, remainingOnly: false) == "No trip is selected.")
    }

    @Test func theRigToolReturnsTheLabeledProfile() {
        let rig = tools.rigOutput()
        #expect(rig.hasPrefix("BEGIN SAVED RIG PROFILE"))
        #expect(rig.contains("Manufacturer: \"Forest River\""))
        #expect(rig.contains("Overall length: 19.5 ft"))
        #expect(CampingTools().rigOutput() == "No rig is saved.")
    }

    @Test func toolDefinitionsAreCountedAndAResultIsReservedFromHistory() async throws {
        let plain = try await request("What's for dinner?", tools: nil).plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        let offered = try await request("What's for dinner?", tools: tools).plan(.full, counter: ConservativeTokenEstimator(), budget: PromptBudget())
        #expect(offered.usage.tools == 3 * CampingTools.schemaTokensPerTool)
        #expect(plain.usage.tools == 0)
        #expect(offered.usage.total >= plain.usage.total + offered.usage.tools)
        #expect(offered.usage.total <= PromptBudget().inputLimit)
        #expect(tools.outputReserveTokens >= CampingTools.outputCharacters / ConservativeTokenEstimator.asciiCharactersPerToken)
        #expect(CampingTools().outputReserveTokens == 0)
    }

    @Test func onlyTripAndMenuLookupsMakeTheSavedTripASource() async throws {
        for (kind, isSource) in [(CampingToolKind.menu, true), (.trip, true), (.rig, false)] {
            let generator = ToolGenerator()
            generator.calls = kind
            let reply = try await CampingGeneration.answer(to: request("Question", tools: tools), using: generator)
            #expect(reply.usedSavedTrip == isSource, "\(kind)")
        }
        let quiet = ToolGenerator()
        let plain = try await CampingGeneration.answer(to: request("How do I level the trailer?", tools: tools), using: quiet)
        #expect(!plain.usedSavedTrip, "No call, no saved-trip source")
        #expect(quiet.offered.first??.kinds == [.menu, .trip, .rig])
    }
}

/// A session that records which stored turn's tool results each request may send, and "calls" a tool when asked.
@MainActor
private final class ResultsModel: CampingChatModel {
    var resultsOf: [CampingChatTurn.ID?] = []
    var histories: [[String]] = []
    /// One output per answer, or nil for an answer without a tool call.
    var outputs: [String?]

    init(outputs: [String?]) { self.outputs = outputs }

    func makeSession(history: [CampingChatTurn]) -> any CampingChatSession { Session(model: self) }
    func summarize(_ turns: [CampingChatTurn], into summary: String?) async throws -> String { "summary" }

    private final class Session: CampingChatSession {
        unowned let model: ResultsModel
        init(model: ResultsModel) { self.model = model }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String { "answer" }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                     tools: CampingTools?, resultsOf: CampingChatTurn.ID?) async throws -> CampingSessionReply {
            model.resultsOf.append(resultsOf)
            model.histories.append(history.map(\.question))
            let output = model.outputs.isEmpty ? nil : model.outputs.removeFirst()
            return CampingSessionReply(text: "answer", toolsUsed: output == nil ? [] : [.menu], toolOutputs: output.map { [$0] } ?? [])
        }
        func store(_ turn: CampingChatTurn) {}
        func remove(_ turnID: CampingChatTurn.ID) {}
    }
}

@MainActor
struct ToolResultHistoryTests {
    private func tools(_ dish: String) -> CampingTools {
        CampingTools(menu: TripMenuFacts(days: [.init(number: 1, label: "Day 1", meals: [
            .init(kind: .dinner, title: "Dinner", dishes: [.init(name: dish, notes: "", items: [])])
        ])]))
    }

    private func ask(_ question: String, _ tools: CampingTools) -> CampingHelpRequest {
        CampingHelpRequest(question: question, steps: [], rigType: nil, step: nil, scope: .checklist, tools: tools)
    }

    @Test func aFollowUpSendsTheNewestTurnsResultsWhileTheDataIsUnchanged() async throws {
        let model = ResultsModel(outputs: ["Day 1 dinner: Chili", nil, nil])
        let chat = CampingChat(model: model, counter: ConservativeTokenEstimator())
        let first = try await chat.answer(ask("What's for dinner?", tools("Chili")))
        _ = try await chat.answer(ask("What goes in it?", tools("Chili")))
        #expect(model.resultsOf == [nil, first.turnID], "The follow-up may use the first turn's results")
        _ = try await chat.answer(ask("And dessert?", tools("Chili")))
        #expect(model.resultsOf.last == .some(nil), "The second turn called no tool, so nothing is kept")
    }

    @Test func editingTheTripDropsTheKeptResults() async throws {
        let model = ResultsModel(outputs: ["Day 1 dinner: Chili", nil])
        let chat = CampingChat(model: model, counter: ConservativeTokenEstimator())
        _ = try await chat.answer(ask("What's for dinner?", tools("Chili")))
        _ = try await chat.answer(ask("What goes in it?", tools("Tacos")))
        #expect(model.resultsOf == [nil, nil], "A changed menu must be looked up again, never answered from the old result")
    }

    @Test func resultsTooLargeToFitAreLeftOutButTheTurnStays() async throws {
        let model = ResultsModel(outputs: [String(repeating: "x", count: 9000), nil])
        let chat = CampingChat(model: model, counter: ConservativeTokenEstimator())
        _ = try await chat.answer(ask("What's for dinner?", tools("Chili")))
        _ = try await chat.answer(ask("What goes in it?", tools("Chili")))
        #expect(model.resultsOf.last == .some(nil))
        #expect(model.histories.last == ["What's for dinner?"], "The earlier turn still goes, without its results")
    }

    @Test func onlyTheNewestTurnsAndCurrentTurnsToolEntriesAreSent() {
        typealias Kind = CampingChatHistory.EntryKind
        let entries: [(String, Kind)] = [
            ("q1", .prompt(id: "1")), ("call1", .tool), ("out1", .tool), ("a1", .response),
            ("q2", .prompt(id: "2")), ("call2", .tool), ("out2", .tool), ("a2", .response),
            ("current", .prompt(id: "now")), ("call", .tool), ("out", .tool)
        ]
        let kept = CampingChatHistory.sent(entries, keeping: ["1", "2"], resultsOf: "2", kind: \.1).map(\.0)
        #expect(kept == ["q1", "a1", "q2", "call2", "out2", "a2", "current", "call", "out"])
        let none = CampingChatHistory.sent(entries, keeping: ["1", "2"], kind: \.1).map(\.0)
        #expect(none == ["q1", "a1", "q2", "a2", "current", "call", "out"], "The current turn's loop always has its own results")
        let dropped = CampingChatHistory.sent(entries, keeping: ["1"], resultsOf: "2", kind: \.1).map(\.0)
        #expect(dropped == ["q1", "a1", "current", "call", "out"], "Results never go without their turn")
    }
}
