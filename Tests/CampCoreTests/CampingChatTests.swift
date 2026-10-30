import XCTest
@testable import CampCore

/// Four characters per token, and a context window the test chooses.
private struct FakeCounter: PromptTokenCounting {
    var contextSize: Int?
    func tokenCount(of text: String) async throws -> Int { (text.count + 3) / 4 }
}

/// Stands in for Apple's session: records what each request was given and keeps a transcript of stored turns.
@MainActor
private final class FakeSession: CampingChatSession {
    struct Call { let prompt: String; let instructions: String; let history: [String] }

    unowned let model: FakeModel
    var transcript: [CampingChatTurn]
    var calls: [Call] = []
    var removed: [String] = []

    init(model: FakeModel, history: [CampingChatTurn]) { self.model = model; transcript = history }

    func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String {
        calls.append(Call(prompt: prompt, instructions: instructions, history: history.map(\.question)))
        XCTAssertTrue(history.allSatisfy { turn in transcript.contains(turn) }, "only stored turns can be sent")
        if model.cancelAfterResponding { withUnsafeCurrentTask { $0?.cancel() } }
        return try model.responses.removeFirst().get()
    }

    func store(_ turn: CampingChatTurn) { transcript.append(turn) }

    func remove(_ turnID: CampingChatTurn.ID) {
        removed.append(turnID)
        transcript.removeAll { $0.id == turnID }
    }
}

@MainActor
private final class FakeModel: CampingChatModel {
    var responses: [Result<String, CampingChatFailure>]
    var sessions: [FakeSession] = []
    var seeds: [[String]] = []
    var cancelAfterResponding = false

    init(_ responses: [Result<String, CampingChatFailure>]) { self.responses = responses }

    func makeSession(history: [CampingChatTurn]) -> any CampingChatSession {
        seeds.append(history.map(\.question))
        let session = FakeSession(model: self, history: history)
        sessions.append(session)
        return session
    }
}

final class CampingChatTests: XCTestCase {
    private func ask(_ question: String, documents: DocumentEvidence? = nil) -> CampingHelpRequest {
        CampingHelpRequest(question: question, steps: [], rigType: nil, step: nil, scope: .general, documents: documents)
    }

    private func turn(_ question: String, size: Int = 0) -> CampingChatTurn {
        CampingChatTurn(question: question, answer: String(repeating: "a", count: size))
    }

    // MARK: Trimming rules

    func testWindowSendsTheNewestTurnsThatFitOldestFirst() {
        let turns = (1...5).map { turn("Q\($0)") }
        let cost: (CampingChatTurn) -> Int = { _ in 10 }
        XCTAssertEqual(CampingChatHistory.window(turns, budget: 1000, cost: cost).map(\.question), ["Q3", "Q4", "Q5"],
                       "never more than three, however much room is left")
        XCTAssertEqual(CampingChatHistory.window(turns, budget: 25, cost: cost).map(\.question), ["Q4", "Q5"])
        XCTAssertTrue(CampingChatHistory.window(turns, budget: 9, cost: cost).isEmpty)
        XCTAssertTrue(CampingChatHistory.window(turns, budget: -40, cost: cost).isEmpty)
    }

    func testWindowStopsAtTheFirstTurnThatDoesNotFitSoItNeverSkipsAhead() {
        let turns = [turn("small"), turn("big"), turn("newest")]
        let sent = CampingChatHistory.window(turns, budget: 30, cost: { $0.question == "big" ? 100 : 10 })
        XCTAssertEqual(sent.map(\.question), ["newest"], "an older small turn isn't sent past a newer one that was dropped")
    }

    func testWindowBeforeATurnSendsOnlyEarlierTurnsAndNothingForOneNoLongerStored() {
        let turns = (1...5).map { turn("Q\($0)") }
        let cost: (CampingChatTurn) -> Int = { _ in 10 }
        XCTAssertEqual(CampingChatHistory.window(turns, before: turns[3].id, budget: 1000, cost: cost).map(\.question), ["Q1", "Q2", "Q3"])
        XCTAssertTrue(CampingChatHistory.window(turns, before: turns[0].id, budget: 1000, cost: cost).isEmpty)
        XCTAssertTrue(CampingChatHistory.window(turns, before: "compacted away", budget: 1000, cost: cost).isEmpty)
    }

    func testTransformKeepsInstructionsChosenTurnsAndTheCurrentPrompt() {
        typealias Kind = CampingChatHistory.EntryKind
        let entries: [(String, Kind)] = [
            ("instructions", .instructions),
            ("q1", .prompt(id: "1")), ("a1", .response),
            ("q2", .prompt(id: "2")), ("r2", .other), ("a2", .response),
            ("q3", .prompt(id: "3")), ("a3", .response),
            ("unknown", .prompt(id: "never stored")), ("a?", .response),
            ("current", .prompt(id: "framework id"))
        ]
        let sent = CampingChatHistory.sent(entries, keeping: ["2", "3"], kind: \.1).map(\.0)
        XCTAssertEqual(sent, ["instructions", "q2", "r2", "a2", "q3", "a3", "current"])
        // With no request in flight the last prompt is a stored turn like any other.
        let stored = CampingChatHistory.sent(Array(entries.prefix(8)), keeping: ["1"], kind: \.1).map(\.0)
        XCTAssertEqual(stored, ["instructions", "q1", "a1"])
    }

    // MARK: One session per chat

    @MainActor func testAChatKeepsOneSessionAndNeverPastesEarlierTurnsIntoThePrompt() async throws {
        let model = FakeModel([.success("Fill the tank."), .success("About ten minutes.")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("How do I fill the fresh tank?"))
        XCTAssertEqual(chat.previousQuestion(), "How do I fill the fresh tank?")
        _ = try await chat.answer(ask("How long does it take?"))
        XCTAssertEqual(model.sessions.count, 1)
        let calls = model.sessions[0].calls
        XCTAssertEqual(calls[0].history, [])
        XCTAssertEqual(calls[1].history, ["How do I fill the fresh tank?"])
        XCTAssertFalse(calls[1].prompt.contains("fresh tank"), "the transcript carries history; the prompt holds only this turn")
        XCTAssertEqual(chat.turns.map(\.answer), ["Fill the tank.", "About ten minutes."])
    }

    @MainActor func testStoredTurnsHoldNoExcerptsOrCitationMarkers() async throws {
        let manual = UUID()
        let candidate = DocumentEvidenceCandidate(documentID: manual, indexedChecksum: "c1", page: 4, section: "Faults",
                                                  text: "Error code E4 means the water heater igniter failed.")
        let live = LiveDocument(id: manual, title: "Water Heater Manual", category: "Manual", checksum: "c1", isInScope: true)
        let evidence = DocumentEvidence.make(question: "error code E4 water heater", candidates: [candidate], live: [manual: live])
        let model = FakeModel([.success("E4 means the igniter failed [S1].")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        let reply = try await chat.answer(ask("What does error code E4 mean on my water heater?", documents: evidence))
        XCTAssertEqual(reply.sources.map(\.id), ["S1"])
        XCTAssertTrue(model.sessions[0].calls[0].prompt.contains("igniter failed."), "the excerpt reaches this turn's prompt")
        let stored = try XCTUnwrap(model.sessions[0].transcript.first)
        XCTAssertEqual(stored.id, reply.turnID)
        XCTAssertEqual(stored.question, "What does error code E4 mean on my water heater?")
        XCTAssertEqual(stored.answer, "E4 means the igniter failed.")
        XCTAssertFalse(stored.answer.contains("[S1]"))
    }

    @MainActor func testHistoryGetsOnlyWhatTheCurrentTurnLeaves() async throws {
        let long = String(repeating: "Check the anode rod and flush the tank. ", count: 24)
        let model = FakeModel(Array(repeating: .success(long), count: 6))
        let roomy = CampingChat(model: model, counter: FakeCounter(contextSize: 100_000))
        for index in 1...5 { _ = try await roomy.answer(ask("Question \(index)")) }
        XCTAssertEqual(model.sessions[0].calls.last?.history, ["Question 2", "Question 3", "Question 4"])

        // A window that holds this turn and about one long earlier turn.
        let request = ask("Question 6")
        let plan = try await request.plan(.full, counter: FakeCounter(), budget: PromptBudget(contextSize: 100_000))
        let tight = FakeModel(Array(repeating: .success(long), count: 3))
        let chat = CampingChat(model: tight, counter: FakeCounter(contextSize: plan.usage.total + 400 + PromptBudget.outputTokens + PromptBudget.reservedTokens))
        _ = try await chat.answer(ask("Question 4"))
        _ = try await chat.answer(ask("Question 5"))
        _ = try await chat.answer(request)
        XCTAssertEqual(tight.sessions[0].calls.last?.history, ["Question 5"], "the current turn is planned first; history gets the rest")
    }

    @MainActor func testANewScopeStartsANewSessionWithNoEarlierTurns() async throws {
        let model = FakeModel([.success("65 psi."), .success("Under the steps."), .success("Five minutes.")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("What is the tire pressure?"), in: "rigA")
        XCTAssertNil(chat.previousQuestion(in: "rigB"))
        _ = try await chat.answer(ask("Where is the fuse box?"), in: "rigB")
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.seeds[1], [])
        XCTAssertEqual(model.sessions[1].calls[0].history, [])
        XCTAssertEqual(chat.turns.map(\.question), ["Where is the fuse box?"])
        chat.reset()
        _ = try await chat.answer(ask("How long do I wait?"), in: "rigB")
        XCTAssertEqual(model.sessions.count, 3, "New chat starts another session")
        XCTAssertEqual(model.sessions[2].calls[0].history, [])
    }

    @MainActor func testAskingAgainSendsOnlyTheTurnsBeforeThatQuestion() async throws {
        let model = FakeModel([.success("A1"), .success("Not ready yet."), .success("A3"), .success("Ready now.")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("Q1"))
        let notReady = try await chat.answer(ask("Q2"))
        _ = try await chat.answer(ask("Q3"))
        let turnID = try XCTUnwrap(notReady.turnID)
        XCTAssertEqual(chat.previousQuestion(before: turnID), "Q1")
        _ = try await chat.answer(ask("Q2"), before: turnID)
        XCTAssertEqual(model.sessions[0].calls.last?.history, ["Q1"])
        XCTAssertEqual(chat.turns.map(\.question), ["Q1", "Q2", "Q3", "Q2"])
    }

    @MainActor func testALongChatKeepsABoundedTranscript() async throws {
        let model = FakeModel(Array(repeating: .success("Fine."), count: 15))
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        for index in 1...15 { _ = try await chat.answer(ask("Q\(index)")) }
        XCTAssertEqual(chat.turns.count, CampingChatHistory.storedTurns)
        XCTAssertEqual(model.sessions[0].transcript.map(\.question), (4...15).map { "Q\($0)" })
    }

    // MARK: Compaction

    @MainActor func testOverflowCompactsToANewSessionWithTheNewestTurnAndAnswers() async throws {
        let model = FakeModel([.success("A1"), .success("A2"), .success("A3"), .failure(.contextTooLong), .success("A4")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        for index in 1...3 { _ = try await chat.answer(ask("Q\(index)")) }
        let request = ask("Q4")
        let reply = try await chat.answer(request)
        XCTAssertEqual(reply.text, "A4")
        XCTAssertEqual(chat.compactions, 1)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.seeds[1], ["Q3"], "the new session starts from the newest turn")
        XCTAssertEqual(model.sessions[0].calls.last?.history, ["Q1", "Q2", "Q3"])
        XCTAssertEqual(model.sessions[1].calls.map(\.history), [["Q3"]])
        XCTAssertEqual(model.sessions[1].calls[0].prompt, request.compactPrompt)
        XCTAssertEqual(chat.turns.map(\.question), ["Q3", "Q4"])
        XCTAssertEqual(model.sessions[1].transcript.map(\.question), ["Q3", "Q4"])
    }

    @MainActor func testAChatThatKeepsOverflowingNeverDeadEnds() async throws {
        let model = FakeModel([.success("A1"), .failure(.contextTooLong), .failure(.contextTooLong), .success("A3")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("Q1"))
        do {
            _ = try await chat.answer(ask("Q2"))
            XCTFail("Both attempts overflowed")
        } catch { XCTAssertEqual(error as? CampingChatFailure, .contextTooLong) }
        XCTAssertEqual(model.sessions[1].calls.count, 1, "one retry, never a loop")
        XCTAssertEqual(chat.turns.map(\.question), ["Q1"], "a failed turn is never stored")
        let next = try await chat.answer(ask("Q3"))
        XCTAssertEqual(next.text, "A3", "the compacted session keeps answering")
    }

    // MARK: Failure and cancellation

    @MainActor func testAFailedTurnLeavesTheConversationAsItWas() async throws {
        let model = FakeModel([.success("A1"), .failure(.busy), .success("   ")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("Q1"))
        do { _ = try await chat.answer(ask("Q2")); XCTFail("busy") } catch { XCTAssertEqual(error as? CampingChatFailure, .busy) }
        do { _ = try await chat.answer(ask("Q3")); XCTFail("empty") } catch { XCTAssertEqual(error as? CampingChatFailure, .failed) }
        XCTAssertEqual(chat.turns.map(\.question), ["Q1"])
        XCTAssertEqual(model.sessions[0].transcript.map(\.question), ["Q1"])
        XCTAssertEqual(chat.compactions, 0)
    }

    @MainActor func testAnAnswerCancelledAfterTheModelFinishedIsForgotten() async throws {
        let model = FakeModel([.success("A1"), .success("Too late.")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("Q1"))
        model.cancelAfterResponding = true
        let task = Task { try await chat.answer(self.ask("Q2")) }
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(chat.turns.map(\.question), ["Q1"])
        XCTAssertEqual(model.sessions[0].transcript.map(\.question), ["Q1"])
        XCTAssertEqual(model.sessions[0].removed.count, 1)
    }

    @MainActor func testAnAnswerTheScreenDroppedCanBeForgotten() async throws {
        let model = FakeModel([.success("A1"), .success("A2"), .success("A3")])
        let chat = CampingChat(model: model, counter: FakeCounter(contextSize: 4096))
        _ = try await chat.answer(ask("Q1"))
        let dropped = try await chat.answer(ask("Q2"))
        chat.forget(try XCTUnwrap(dropped.turnID))
        _ = try await chat.answer(ask("Q3"))
        XCTAssertEqual(model.sessions[0].calls.last?.history, ["Q1"])
    }
}
