import Testing
import Foundation
import CampCore
import DocumentSearch
@testable import AssistantEval

@MainActor
private struct StubGenerator: CampingResponseGenerating {
    func respond(to prompt: String, instructions: String) async throws -> String {
        prompt.contains("\n[S1] ") ? "From your documents. [S1] Also [S9]." : "The documents do not cover that."
    }
}

@MainActor
@Suite("Generated-answer review sheets")
struct GenerationEvalTests {
    private func options(_ ids: Set<String>? = nil, samples: Int = 2) -> GenerationEvalOptions {
        var options = GenerationEvalOptions()
        options.samples = samples
        options.scenarioIDs = ids
        return options
    }

    @Test func unavailableModelIsNotRunAndNeverPasses() async throws {
        let backend = GenerationBackend(availability: .unavailable(reason: "no model here"), label: "stub", generator: StubGenerator())
        let review = try await GenerationEvalRunner.run(corpus: try EvalCorpus.bundled(), retrieval: .lexicalOnly, backend: backend, options: options())
        #expect(review.status == GenerationReview.notRun)
        #expect(review.notRunReason == "no model here")
        #expect(review.scenarios.isEmpty)
        #expect(review.markdown().contains("NOT RUN"))
    }

    @Test func scenariosReuseCorpusCasesAndCoverTheRequiredGroups() throws {
        let scenarios = try GenerationScenarios.all(corpus: try EvalCorpus.bundled())
        let groups = Set(scenarios.map(\.group))
        for group in [GenerationScenario.Group.conflict, .conflictControl, .readiness, .language, .scopeSwitch, .exclusion] {
            #expect(groups.contains(group))
        }
        #expect(Set(scenarios.map(\.id)).count == scenarios.count)
        #expect(scenarios.contains { $0.kind == .challenge })
        #expect(scenarios.first { $0.id == "followup-rig-switch" }?.turns.count == 2)
    }

    @Test func sheetsRecordEvidenceCitationsAndLeaveTheRubricEmpty() async throws {
        let backend = GenerationBackend(availability: .available(details: [:]), label: "stub", generator: StubGenerator())
        let review = try await GenerationEvalRunner.run(
            corpus: try EvalCorpus.bundled(), retrieval: .embedding(DeterministicEmbeddingProvider(), label: "fake"), backend: backend,
            options: options(["conflict-two-confirmations", "followup-document-exclusion", "language-non-english", "readiness-before"]))
        #expect(review.status == GenerationReview.ready)
        let conflict = try #require(review.scenarios.first { $0.id == "conflict-two-confirmations" })
        let turn = try #require(conflict.turns.first)
        #expect(turn.supplied.contains { $0.document == "pinecrest-confirmation" } && turn.supplied.contains { $0.document == "pinecrest-amended" })
        #expect(turn.answers.count == 2)
        let answer = try #require(turn.answers.first)
        #expect(answer.validatedCitations.map(\.id) == ["S1"])
        #expect(answer.rejectedCitationIDs == 1)
        #expect(answer.rubric == GenerationReview.Rubric())
        #expect(answer.rawText.contains("[S9]"))

        // Excluding the manual between follow-ups removes it from the second turn and leaves nothing to cite.
        let exclusion = try #require(review.scenarios.first { $0.id == "followup-document-exclusion" })
        #expect(exclusion.turns[0].supplied.contains { $0.document == "aqua-manual" })
        #expect(!exclusion.turns[1].supplied.contains { $0.document == "aqua-manual" })

        // A non-English question gets the fixed notice and no model call.
        let language = try #require(review.scenarios.first { $0.id == "language-non-english" })
        #expect(language.turns[0].englishOnlyNotice != nil)
        #expect(language.turns[0].answers.isEmpty)

        // The scan that has not arrived is named as not ready in the captured readiness.
        let readiness = try #require(review.scenarios.first { $0.id == "readiness-before" })
        #expect(readiness.turns[0].readiness?.contains("waiting for download") == true)

        for scenario in review.scenarios {
            for turn in scenario.turns {
                #expect(turn.crossScopeOrExcludedSources.isEmpty)
                #expect(turn.staleSources.isEmpty)
            }
        }
        #expect(!review.markdown().isEmpty && !conflict.markdown(in: review).isEmpty)
    }
}
