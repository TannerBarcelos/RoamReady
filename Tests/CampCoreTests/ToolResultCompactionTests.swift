import Foundation
import Testing
@testable import CampCore

private struct CharacterTokenCounter: PromptTokenCounting {
    let contextSize: Int? = 2048
    func tokenCount(of text: String) async throws -> Int { text.count }
}

@MainActor
struct ToolResultCompactionTests {
    @Test func fittingResultsPassThroughWithoutAnotherModelCall() async throws {
        let result = try await ToolResultCompaction.fit("Complete resource", question: "Anything", tokenLimit: 400,
                                                       counter: CharacterTokenCounter()) { _, _ in
            Issue.record("A fitting result should not be summarized")
            return ""
        }
        #expect(result == "Complete resource")
    }

    @Test func oversizedResultsAreEntirelyProcessedInBoundedSessions() async throws {
        let raw = String(repeating: "Reference: quantities 2 kg; dates; 世界.\n", count: 150) + "Last record."
        var chunks: [String] = []
        let result = try await ToolResultCompaction.fit(raw, question: "What is saved?", tokenLimit: 400,
                                                       counter: CharacterTokenCounter()) { prompt, outputTokens in
            #expect(ToolResultCompaction.instructions.count + prompt.count + outputTokens + PromptBudget.reservedTokens <= 2048)
            chunks.append(try #require(prompt.components(separatedBy: "New reference data:\n").last))
            return "Condensed facts from \(chunks.count) sections."
        }
        #expect(chunks.count > 1)
        #expect(chunks.joined() == raw, "Every character, including later records, reaches the compactor")
        #expect(result.count <= 400)
        #expect(result.contains("details may be omitted"), "A model summary must not masquerade as the original")
    }

    @Test func unusableSummariesFailRatherThanSilentlyTruncateData() async {
        for summary in ["", String(repeating: "x", count: 2000)] {
            do {
                _ = try await ToolResultCompaction.fit(String(repeating: "data ", count: 500), question: "Q", tokenLimit: 400,
                                                       counter: CharacterTokenCounter()) { _, _ in summary }
                Issue.record("Expected a failed compaction")
            } catch { #expect(error is CampingChatFailure) }
        }
    }

    @Test func cancellationStopsBeforeReadingOrSummarizing() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolResultCompaction.fit("data", question: "Q", tokenLimit: 400,
                                                     counter: CharacterTokenCounter()) { _, _ in
                Issue.record("Cancelled work must not invoke a model")
                return "summary"
            }
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }
}
