import XCTest
@testable import CampCore

/// Four characters per token, and a context window the test chooses.
private struct FakeCounter: PromptTokenCounting {
    var contextSize: Int?
    var fails = false
    func tokenCount(of text: String) async throws -> Int {
        if fails { throw CampingChatFailure.failed }
        return (text.count + 3) / 4
    }
}

@MainActor
private final class ScriptedGenerator: CampingResponseGenerating {
    var prompts: [String] = []
    var responses: [Result<String, CampingChatFailure>]
    init(_ responses: [Result<String, CampingChatFailure>]) { self.responses = responses }
    func respond(to prompt: String, instructions: String) async throws -> String {
        prompts.append(prompt)
        return try responses.removeFirst().get()
    }
}

final class PromptBudgetTests: XCTestCase {
    private let manual = UUID()

    /// Everything shrinkable is present and large: long checklist guidance and four excerpts.
    private func request(question: String = "What does error code E4 mean on my water heater?",
                         excerpts: Int = 4) -> CampingHelpRequest {
        let steps = (1...6).map {
            ChecklistStepDraft(title: "Water heater step \($0)", detail: String(repeating: "Check the water heater error code carefully. ", count: 20))
        }
        let candidates = (1...excerpts).map {
            DocumentEvidenceCandidate(documentID: manual, indexedChecksum: "c1", page: $0, section: "Troubleshooting",
                                      text: "Page \($0): error code E4 water heater igniter failed. " + String(repeating: "More detail. ", count: 50))
        }
        let live = LiveDocument(id: manual, title: "Water Heater Manual", category: "Manual", checksum: "c1", isInScope: true)
        let evidence = DocumentEvidence.make(question: "error code E4 water heater", candidates: candidates, live: [manual: live])
        return CampingHelpRequest(question: question, steps: steps, rigType: nil, step: nil, scope: .general,
                                  documents: evidence)
    }

    private func budget(inputLimit: Int) -> PromptBudget {
        PromptBudget(contextSize: inputLimit + PromptBudget.outputTokens + PromptBudget.reservedTokens)
    }

    // MARK: Counting

    func testEstimatorNeverTreatsCharactersAsTokensAndErrsHigh() async throws {
        let estimator = ConservativeTokenEstimator()
        let ascii = String(repeating: "word ", count: 60)
        let accented = String(repeating: "é", count: 60)
        let asciiTokens = try await estimator.tokenCount(of: ascii)
        let accentedTokens = try await estimator.tokenCount(of: accented)
        XCTAssertGreaterThanOrEqual(asciiTokens, ascii.count / 4, "never fewer than a four-characters-per-token guess")
        XCTAssertGreaterThan(accentedTokens, accented.count / 4)
        XCTAssertEqual(accentedTokens, 90, "1.5 tokens per non-ASCII character; the model measured about one")
    }

    func testBudgetReservesTheOutputTargetAndUsesTheModelWindow() {
        XCTAssertEqual(PromptBudget.outputTokens, 512)
        XCTAssertEqual(PromptBudget().contextSize, 4096)
        XCTAssertEqual(PromptBudget(contextSize: 8192).contextSize, 8192)
        XCTAssertEqual(PromptBudget(contextSize: 4096).inputLimit, 4096 - 512 - PromptBudget.reservedTokens)
        XCTAssertEqual(PromptBudget(contextSize: 100).inputLimit, 0)
    }

    func testAZeroOrNegativeWindowFallsBackToTheDocumentedSize() {
        XCTAssertEqual(PromptBudget(contextSize: 0).contextSize, PromptBudget.fallbackContextSize)
        XCTAssertEqual(PromptBudget(contextSize: -1).contextSize, PromptBudget.fallbackContextSize)
    }

    // MARK: Planning

    func testPlansMatchTheUnbudgetedPromptsWhenEverythingFits() async throws {
        let request = request()
        let big = PromptBudget(contextSize: 100_000)
        let full = try await request.plan(.full, counter: FakeCounter(), budget: big)
        let compact = try await request.plan(.compact, counter: FakeCounter(), budget: big)
        XCTAssertEqual(full.prompt, request.prompt)
        XCTAssertEqual(compact.prompt, request.compactPrompt)
        XCTAssertEqual(full.sources.map(\.id), request.documents?.manifest(compact: false).map(\.id))
        XCTAssertEqual(compact.sources.map(\.id), ["S1"])
    }

    func testEveryPartIsCountedAndTheTotalFitsWithTheOutputReserved() async throws {
        let request = request()
        let budget = PromptBudget(contextSize: 4096)
        let plan = try await request.plan(.full, counter: FakeCounter(), budget: budget)
        let usage = plan.usage
        for part in [usage.instructions, usage.checklist, usage.evidence, usage.question] {
            XCTAssertGreaterThan(part, 0)
        }
        XCTAssertLessThanOrEqual(usage.total, budget.inputLimit)
        XCTAssertLessThanOrEqual(usage.total + PromptBudget.outputTokens + PromptBudget.reservedTokens, budget.contextSize)
    }

    func testOverflowingPartsAreShrunkUntilTheWholeFitsAtEveryLimit() async throws {
        let request = request()
        var shrunkAtLeastOnce = false
        for limit in stride(from: 3000, through: 400, by: -50) {
            let budget = budget(inputLimit: limit)
            do {
                let plan = try await request.plan(.full, counter: FakeCounter(), budget: budget)
                XCTAssertLessThanOrEqual(plan.usage.total, limit)
                shrunkAtLeastOnce = shrunkAtLeastOnce || plan.prompt != request.prompt
            } catch {
                XCTAssertEqual(error as? CampingChatFailure, .contextTooLong)
            }
        }
        XCTAssertTrue(shrunkAtLeastOnce)
    }

    func testShrinkingTrimsChecklistBeforeEvidenceAndKeepsTheQuestionLast() async throws {
        let request = request()
        let initial = request.initialShape(.full)
        XCTAssertEqual(initial.excerptCount, 3, "the 2,400-character evidence cap already leaves the 4th out")
        var previous = initial
        var order: [String] = []
        var seen = Set<String>()
        for limit in stride(from: 3000, through: 300, by: -10) {
            guard let plan = try? await request.plan(.full, counter: FakeCounter(), budget: budget(inputLimit: limit)) else { break }
            let shape = plan.shape
            // Parts only ever shrink as the budget does.
            XCTAssertLessThanOrEqual(shape.checklistCharacters, previous.checklistCharacters)
            XCTAssertLessThanOrEqual(shape.excerptCount, previous.excerptCount)
            XCTAssertLessThanOrEqual(shape.excerptCharacters, previous.excerptCharacters)
            XCTAssertLessThanOrEqual(shape.questionCharacters, previous.questionCharacters)
            // Nothing later in the order shrinks while something earlier remains.
            if shape.excerptCount < initial.excerptCount { XCTAssertEqual(shape.checklistCharacters, 0) }
            if shape.excerptCharacters < initial.excerptCharacters { XCTAssertEqual(shape.excerptCount, 1) }
            if shape.questionCharacters < initial.questionCharacters {
                XCTAssertEqual(shape.excerptCharacters, PromptShape.excerptSteps.last)
            }
            // The question and the strongest excerpt are never dropped.
            XCTAssertTrue(plan.prompt.contains("Current question: What does error code E4"))
            XCTAssertEqual(plan.sources.first?.id, "S1")
            for (name, hit) in [("checklist", shape.checklistCharacters < initial.checklistCharacters),
                                ("weaker evidence", shape.excerptCount < initial.excerptCount),
                                ("evidence text", shape.excerptCharacters < initial.excerptCharacters),
                                ("question", shape.questionCharacters < initial.questionCharacters)]
            where hit && seen.insert(name).inserted { order.append(name) }
            previous = shape
        }
        XCTAssertEqual(order, ["checklist", "weaker evidence", "evidence text"],
                       "each stage must be reached in priority order; the question is shortened only at the floor")
    }

    func testFixedInstructionsThatCannotFitFailInsteadOfSendingAnOverflow() async {
        let request = request()
        do {
            _ = try await request.plan(.full, counter: FakeCounter(), budget: budget(inputLimit: 50))
            XCTFail("Instructions alone exceed 50 tokens")
        } catch { XCTAssertEqual(error as? CampingChatFailure, .contextTooLong) }
    }

    func testRunTimeCounterFailureFallsBackToTheEstimator() async throws {
        let request = request()
        let plan = try await request.plan(.full, counter: FakeCounter(fails: true), budget: PromptBudget(contextSize: 4096))
        let estimate = ConservativeTokenEstimator()
        let expected = try await estimate.tokenCount(of: plan.instructions) + estimate.tokenCount(of: plan.prompt)
        XCTAssertEqual(plan.usage.total, expected)
        XCTAssertLessThanOrEqual(plan.usage.total, PromptBudget(contextSize: 4096).inputLimit)
    }

    // MARK: Generation

    @MainActor func testPreflightShrinksTheFirstAttemptAndCitationsToDroppedPassagesAreRejected() async throws {
        let request = request()
        let full = try await request.plan(.full, counter: FakeCounter(), budget: PromptBudget(contextSize: 100_000))
        // A window that can't hold the checklist context and the third excerpt.
        let limit = full.usage.total - full.usage.checklist - 100
        let window = limit + PromptBudget.outputTokens + PromptBudget.reservedTokens
        let generator = ScriptedGenerator([.success("E4 is the igniter [S1] [S3].")])
        let reply = try await CampingGeneration.answer(to: request, using: generator, counter: FakeCounter(contextSize: window))
        XCTAssertEqual(generator.prompts.count, 1, "the model is never sent a prompt known not to fit")
        XCTAssertNotEqual(generator.prompts[0], request.prompt)
        XCTAssertFalse(generator.prompts[0].contains("[S3]"))
        XCTAssertEqual(reply.sources.map(\.id), ["S1"])
        XCTAssertEqual(reply.droppedCitationCount, 1)
    }

    @MainActor func testOverflowAtTheModelRetriesCompactlyWithItsOwnSourceListAndStillAnswers() async throws {
        let request = request()
        let generator = ScriptedGenerator([.failure(.contextTooLong), .success("Igniter failed [S1] [S2] [S3].")])
        let reply = try await CampingGeneration.answer(to: request, using: generator,
                                                       counter: FakeCounter(contextSize: 100_000))
        XCTAssertEqual(generator.prompts, [request.prompt, request.compactPrompt])
        XCTAssertEqual(reply.text, "Igniter failed.")
        XCTAssertEqual(reply.sources.map(\.id), ["S1"])
        XCTAssertEqual(reply.droppedCitationCount, 2, "S2 and S3 were in the first attempt but not the retry")
        XCTAssertEqual(reply.coverage, .cited)
    }

    func testRetryNeverCarriesMoreThanTheAttemptItReplaces() {
        let request = request()
        // The first attempt was already squeezed to one 200-character excerpt and a 250-character checklist.
        var squeezed = request.initialShape(.full)
        squeezed.excerptCount = 1; squeezed.excerptCharacters = 200; squeezed.checklistCharacters = 250
        let retry = request.initialShape(.compact).limited(by: squeezed)
        XCTAssertEqual(retry.excerptCharacters, 200, "the compact default of 400 would be larger than what already failed")
        XCTAssertEqual(retry.checklistCharacters, 250)
        XCTAssertEqual(retry.excerptCount, 1)
    }

    @MainActor func testRetryIdenticalToTheFailedAttemptIsNotSent() async {
        let request = CampingHelpRequest(question: "Hi", steps: [], rigType: nil, step: nil, scope: .general,
                                         documents: DocumentEvidence(excerpts: []))
        let generator = ScriptedGenerator([.failure(.contextTooLong), .success("unused")])
        // No history, checklist, or excerpts: the compact retry would be the same request, so it isn't sent.
        do {
            _ = try await CampingGeneration.answer(to: request, using: generator)
            XCTFail("An identical retry would overflow again")
        } catch { XCTAssertEqual(error as? CampingChatFailure, .contextTooLong) }
        XCTAssertEqual(generator.prompts.count, 1)
        let squeezed = ScriptedGenerator([.failure(.contextTooLong)])
        do {
            let tiny = FakeCounter(contextSize: 700)
            _ = try await CampingGeneration.answer(to: request, using: squeezed, counter: tiny)
            XCTFail("Instructions alone don't fit")
        } catch { XCTAssertEqual(error as? CampingChatFailure, .contextTooLong) }
        XCTAssertTrue(squeezed.prompts.isEmpty)
    }

    @MainActor func testCancellationIsNotReportedAsACounterFailure() async {
        struct Cancelling: PromptTokenCounting {
            var contextSize: Int? { nil }
            func tokenCount(of text: String) async throws -> Int { throw CancellationError() }
        }
        do {
            _ = try await CampingGeneration.answer(to: request(), using: ScriptedGenerator([.success("x")]), counter: Cancelling())
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
