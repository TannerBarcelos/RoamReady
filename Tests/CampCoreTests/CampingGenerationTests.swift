import XCTest
@testable import CampCore

@MainActor
private final class StubCampingGenerator: CampingResponseGenerating {
    var prompts: [String] = []
    var instructions: [String] = []
    var responses: [Result<String, CampingChatFailure>]
    var cancels = false

    init(_ responses: [Result<String, CampingChatFailure>]) { self.responses = responses }
    func respond(to prompt: String, instructions: String) async throws -> String {
        prompts.append(prompt)
        self.instructions.append(instructions)
        if cancels { throw CancellationError() }
        return try responses.removeFirst().get()
    }
}

final class CampingGenerationTests: XCTestCase {
    private func request() -> CampingHelpRequest {
        CampingHelpRequest(question: "How can I keep drinking water clean?", steps: [], rigType: nil,
                           step: nil, scope: .general,
                           history: [CampingChatTurn(question: "Old question", answer: "Old response")])
    }

    @MainActor func testSendReachesGeneratorWithoutTripOrSavedGuidance() async throws {
        let generator = StubCampingGenerator([.success("  Use clean containers.  ")])
        let response = try await CampingGeneration.reply(to: request(), using: generator)
        XCTAssertEqual(response, "Use clean containers.")
        XCTAssertEqual(generator.prompts.count, 1)
        XCTAssertTrue(generator.prompts[0].contains("How can I keep drinking water clean?"))
        XCTAssertTrue(generator.instructions[0].contains("general camping"))
    }

    @MainActor func testContextOverflowRetriesOnceWithFreshCompactPrompt() async throws {
        let generator = StubCampingGenerator([.failure(.contextTooLong), .success("Clean the container.")])
        let request = request()
        _ = try await CampingGeneration.reply(to: request, using: generator)
        XCTAssertEqual(generator.prompts, [request.prompt, request.compactPrompt])
        XCTAssertFalse(generator.prompts[1].contains("Old question"))
        XCTAssertTrue(generator.prompts[1].contains("How can I keep drinking water clean?"))
    }

    @MainActor func testSecondOverflowAndOtherErrorsReachTheUIInsteadOfFakeAnswers() async {
        for failure in [CampingChatFailure.contextTooLong, .unsupportedLanguage, .refused, .busy, .notReady, .failed] {
            let generator = StubCampingGenerator([.failure(failure), .failure(failure)])
            do {
                _ = try await CampingGeneration.reply(to: request(), using: generator)
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertEqual(error as? CampingChatFailure, failure)
                XCTAssertEqual(generator.prompts.count, failure == .contextTooLong ? 2 : 1)
            }
        }
    }

    @MainActor func testEmptyResponseIsAnError() async {
        let generator = StubCampingGenerator([.success(" \n ")])
        do {
            _ = try await CampingGeneration.reply(to: request(), using: generator)
            XCTFail("An empty model response must not be shown as success")
        } catch { XCTAssertEqual(error as? CampingChatFailure, .failed) }
    }

    @MainActor func testLongQuestionIsRejectedInsteadOfSilentlySendingOnlyItsPrefix() async {
        let generator = StubCampingGenerator([])
        let request = CampingHelpRequest(question: String(repeating: "x", count: 1501), steps: [], rigType: nil,
                                        step: nil, scope: .general)
        do {
            _ = try await CampingGeneration.reply(to: request, using: generator)
            XCTFail("The user must be asked to shorten their question")
        } catch { XCTAssertEqual(error as? CampingChatFailure, .contextTooLong) }
        XCTAssertTrue(generator.prompts.isEmpty)
    }

    @MainActor func testCancellationDoesNotBecomeAnAnswerOrTriggerRetry() async {
        let generator = StubCampingGenerator([])
        generator.cancels = true
        do {
            _ = try await CampingGeneration.reply(to: request(), using: generator)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(generator.prompts.count, 1)
    }
}
