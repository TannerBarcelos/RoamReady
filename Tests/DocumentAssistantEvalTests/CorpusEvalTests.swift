import XCTest
import DocumentSearch
@testable import AssistantEval

/// The deterministic part of the retrieval eval: the versioned corpus run through the real search index with
/// no embedding model, and with the fake embeddings. The real Apple embeddings are a manual command
/// (`swift run assistant-eval`), because they depend on the machine.
final class CorpusEvalTests: XCTestCase {
    private func corpus() throws -> EvalCorpus { try EvalCorpus.bundled() }

    // MARK: Corpus

    func testCorpusIsSyntheticVersionedAndCoversTheRequiredScenarios() throws {
        let corpus = try corpus()
        XCTAssertTrue(corpus.synthetic)
        XCTAssertEqual(corpus.version, "1")
        XCTAssertTrue((20...35).contains(corpus.cases.count), "about 20-30 questions, got \(corpus.cases.count)")
        for subset in EvalCorpus.Subset.allCases {
            XCTAssertGreaterThanOrEqual(corpus.cases.filter { $0.subset == subset && $0.kind == .required }.count, 8, "\(subset) needs required cases")
        }
        XCTAssertFalse(corpus.cases.filter { $0.kind == .challenge }.isEmpty)
        XCTAssertTrue(corpus.cases.filter { $0.kind == .challenge && $0.pendingFeature != nil }.count >= 2, "pending-feature cases are challenge cases")

        let tags = Set(corpus.cases.flatMap { $0.tags ?? [] })
        for needed in ["paraphrase", "exact-code", "reservation", "two-rigs", "two-trips", "moved", "deleted", "opt-in", "excluded-category",
                       "unavailable-bytes", "stale", "conflict", "conflict-control", "saved-trip", "unanswerable", "injection", "ocr-noise", "compact-retry"] {
            XCTAssertTrue(tags.contains(needed), "no case is tagged \(needed)")
        }
        // Labels are keyed by document and version, so chunk IDs can't be among them.
        let json = try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "corpus-v1", withExtension: "json", subdirectory: "Corpus")), encoding: .utf8)
        XCTAssertFalse(json.contains("chunkID"))
        XCTAssertFalse(json.contains("passageID"))
    }

    func testCorpusRejectsLabelsThatDoNotPointAtRealText() throws {
        var broken = try corpus()
        let index = try XCTUnwrap(broken.cases.firstIndex { $0.id == "code-e4-with-context" })
        broken.cases[index].evidence?[0].anyOf[0].quote = "text that is not on the page"
        XCTAssertThrowsError(try broken.validate())

        var wrongVersion = try corpus()
        wrongVersion.cases[index].evidence?[0].anyOf[0].version = "v9"
        XCTAssertThrowsError(try wrongVersion.validate())
    }

    func testOverlappingLabelsAreOneEvidenceUnit() throws {
        var corpus = try corpus()
        let index = try XCTUnwrap(corpus.cases.firstIndex { $0.id == "code-e4-with-context" })
        // A second group labeling the same sentence (a longer quote around it) must not be counted twice.
        corpus.cases[index].evidence?.append(.init(id: "e4-again", anyOf: [
            .init(document: "aqua-manual", version: "v1", page: 12, quote: "Error code E4 means the water heater igniter failed to light")
        ]))
        XCTAssertEqual(try corpus.units(for: corpus.cases[index]).count, 1)
        // A different sentence on the same page is a separate unit.
        corpus.cases[index].evidence?.append(.init(id: "wait", anyOf: [
            .init(document: "aqua-manual", version: "v1", page: 12, quote: "wait five minutes before retrying")
        ]))
        XCTAssertEqual(try corpus.units(for: corpus.cases[index]).count, 2)
    }

    // MARK: Lexical run

    func testEveryRequiredCasePassesWithLexicalSearch() async throws {
        let report = try await EvalRunner.run(corpus: corpus(), retrieval: .lexicalOnly)
        XCTAssertEqual(report.outcome, .passed, "failing required cases: \(report.required.failedCases) \(report.cases.filter { !$0.passed && $0.kind == "required" }.flatMap(\.failures))")

        let required = report.required
        XCTAssertEqual(required.passed, required.cases)
        XCTAssertEqual(required.hitAt5, 1.0)
        XCTAssertEqual(required.recallAt5, 1.0)
        XCTAssertGreaterThanOrEqual(required.mrr ?? 0, 0.9)
        XCTAssertEqual(required.exactCodeSuccess, 1.0)
        XCTAssertEqual(required.scopeViolations, 0)
        XCTAssertEqual(required.staleEvidence, 0)
        XCTAssertEqual(required.noEvidenceFalsePositives, 0)
        XCTAssertEqual(required.citationValidity, 1.0)
        XCTAssertEqual(required.promptFailures, 0)
        XCTAssertEqual(report.requiredDev.cases + report.requiredHeldOut.cases, required.cases)

        // Violations are per case, never only in aggregate: every case carries its own lists.
        for item in report.cases {
            XCTAssertTrue(item.scopeViolations.isEmpty, "\(item.id) leaked out of scope: \(item.scopeViolations)")
            XCTAssertTrue(item.staleEvidence.isEmpty, "\(item.id) cited stale evidence")
            XCTAssertTrue(item.citationFailures.isEmpty, "\(item.id): \(item.citationFailures)")
            XCTAssertTrue(item.promptFailures.isEmpty, "\(item.id): \(item.promptFailures)")
        }
    }

    func testChallengeCasesAreReportedApartFromRequiredOnes() async throws {
        let corpus = try corpus()
        let report = try await EvalRunner.run(corpus: corpus, retrieval: .lexicalOnly)
        XCTAssertEqual(report.challenge.cases, corpus.cases.filter { $0.kind == .challenge }.count)
        XCTAssertEqual(report.required.cases, corpus.cases.filter { $0.kind == .required }.count)
        XCTAssertEqual(report.required.cases + report.challenge.cases, report.cases.count)
        // A failing challenge case never turns a release gate red.
        XCTAssertEqual(report.outcome, .passed)
        XCTAssertFalse(report.challenge.failedCases.isEmpty, "the challenge set should still hold known-hard cases")
    }

    func testTheLiveCheckStopsMovedDeletedAndReplacedDocuments() async throws {
        let report = try await EvalRunner.run(corpus: corpus(), retrieval: .lexicalOnly)
        func result(_ id: String) throws -> EvalReport.CaseResult { try XCTUnwrap(report.cases.first { $0.id == id }) }
        // Search still returned them (a stale allow-list, or a file replaced and not yet re-indexed) ...
        XCTAssertFalse(try result("moved-document").droppedByLiveCheck.isEmpty)
        XCTAssertFalse(try result("conflict-deleted-booking").droppedByLiveCheck.isEmpty)
        XCTAssertFalse(try result("replaced-document").droppedByLiveCheck.isEmpty)
        // ... and the live check kept them out of the evidence.
        for id in ["moved-document", "conflict-deleted-booking", "replaced-document", "unavailable-bytes", "opted-out-other"] {
            let titles = try result(id).evidence.map(\.document)
            XCTAssertFalse(titles.contains("fridge-manual") || titles.contains("pinecrest-first-booking") || titles.contains("furnace-manual")
                           || titles.contains("fridge-scan") || titles.contains("summit-notes"), id)
        }
    }

    // MARK: Fake embeddings

    func testFakeEmbeddingsKeepEverySafetyInvariant() async throws {
        let report = try await EvalRunner.run(corpus: corpus(), retrieval: .embedding(DeterministicEmbeddingProvider(), label: "deterministic fake embeddings"))
        XCTAssertNotEqual(report.outcome, .notRun)
        XCTAssertEqual(report.metadata.embeddingDimension, 64)
        // The fake's hashed vectors reorder results, so ranking quality isn't gated here (the lexical run and the Apple
        // run measure it). What must hold for any embedding is that nothing out of scope, stale, or forged gets through.
        for aggregate in [report.required, report.challenge] {
            XCTAssertEqual(aggregate.scopeViolations, 0)
            XCTAssertEqual(aggregate.staleEvidence, 0)
            XCTAssertEqual(aggregate.citationValidity, 1.0)
        }
        // Whether the compact retry's strongest excerpt holds the answer depends on ranking, so it's not an invariant.
        for item in report.cases {
            XCTAssertTrue(item.promptFailures.filter { !$0.contains("strongest excerpt no longer contains") }.isEmpty, "\(item.id): \(item.promptFailures)")
        }
        XCTAssertGreaterThanOrEqual(report.required.hitAt5 ?? 0, 0.9)
        XCTAssertEqual(report.required.noEvidenceFalsePositives, 0)
    }

    // MARK: Metrics

    func testHitAtFiveIsNotRecallAtFiveAndMRRSkipsUnanswerableCases() async throws {
        var corpus = try corpus()
        // The conflict case needs two units. Pointing one at a document that is not in scope leaves Hit@5 at 1 and Recall@5 at 0.5.
        let index = try XCTUnwrap(corpus.cases.firstIndex { $0.id == "conflict-checkin" })
        corpus.cases[index].evidence?[1] = .init(id: "unreachable", anyOf: [
            .init(document: "brandx-manual", version: "v1", page: 6, quote: "drain the water lines and the water heater")
        ])
        corpus.cases = corpus.cases.filter { ["conflict-checkin", "unanswerable-off-topic"].contains($0.id) }
        let report = try await EvalRunner.run(corpus: try EvalCorpus.validated(corpus), retrieval: .lexicalOnly)

        let conflict = try XCTUnwrap(report.cases.first { $0.id == "conflict-checkin" })
        XCTAssertEqual(conflict.hitAt5, true)
        XCTAssertEqual(conflict.recallAt5, 0.5)
        XCTAssertFalse(conflict.passed)
        XCTAssertTrue(conflict.failures.contains { $0.contains("Missed evidence `unreachable`") && $0.contains("outside the search scope") }, "\(conflict.failures)")

        // One answerable case and one unanswerable one: the aggregate averages over the answerable case alone.
        XCTAssertEqual(report.required.answerable, 1)
        XCTAssertEqual(report.required.unanswerable, 1)
        XCTAssertEqual(report.required.mrr, conflict.reciprocalRank)
        XCTAssertEqual(report.required.hitAt5, 1.0)
        XCTAssertEqual(report.required.recallAt5, 0.5)
        XCTAssertEqual(report.outcome, .failed)
    }

    func testAMissedExpectationNamesTheEvidenceAndWhatWasRetrievedInstead() async throws {
        var corpus = try corpus()
        let index = try XCTUnwrap(corpus.cases.firstIndex { $0.id == "code-e4-with-context" })
        corpus.cases[index].evidence = [.init(id: "wrong", anyOf: [.init(document: "summit-warranty", version: "v1", page: 1, quote: "three years from the date of purchase")])]
        corpus.cases = [corpus.cases[index]]
        let report = try await EvalRunner.run(corpus: try EvalCorpus.validated(corpus), retrieval: .lexicalOnly)
        let item = try XCTUnwrap(report.cases.first)
        XCTAssertFalse(item.passed)
        XCTAssertEqual(item.hitAt5, false)
        XCTAssertEqual(item.reciprocalRank, 0)
        XCTAssertFalse(item.search.isEmpty, "the actual results are listed next to the expected ones")
        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("Missed evidence `wrong`"))
        XCTAssertTrue(markdown.contains("Aqua-Glo Water Heater Manual"))
    }

    // MARK: Reports

    func testReportsRoundTripAsJSONAndRenderAsMarkdown() async throws {
        let report = try await EvalRunner.run(corpus: corpus(), retrieval: .lexicalOnly)
        let decoded = try EvalReport.decode(report.json())
        XCTAssertEqual(decoded.cases.count, report.cases.count)
        XCTAssertEqual(decoded.required, report.required)
        XCTAssertEqual(decoded.metadata.corpusChecksum, report.metadata.corpusChecksum)
        XCTAssertEqual(decoded.metadata.chunkingVersion, PassageChunker.version)
        XCTAssertEqual(decoded.metadata.retrieval, "lexical-only")

        let markdown = report.markdown()
        for heading in ["Hit@5", "Recall@5", "MRR (answerable only)", "Exact-code success", "Scope / exclusion violations", "Stale evidence",
                        "No-evidence false positives", "Citation validity", "Failures and misses", "Expected and actual evidence, every case"] {
            XCTAssertTrue(markdown.contains(heading), heading)
        }
        XCTAssertTrue(markdown.contains("general-chat-common-words"), "challenge failures are explained in the report")
        XCTAssertTrue(markdown.contains("Generation:"))
        XCTAssertFalse(markdown.contains("Pat Example"), "private-looking text never needs to be in a report")
    }

    // MARK: Not run

    func testAnUnavailableEmbeddingIsNotRunAndNeverAPass() async throws {
        let unavailable = DeterministicEmbeddingProvider(isAvailable: false)
        let report = try await EvalRunner.run(corpus: corpus(), retrieval: .embedding(unavailable, label: "Apple NLEmbedding"))
        XCTAssertEqual(report.outcome, .notRun)
        XCTAssertNotEqual(report.outcome, .passed)
        XCTAssertNotNil(report.notRunReason)
        XCTAssertTrue(report.cases.isEmpty)
        XCTAssertNil(report.required.hitAt5)
        XCTAssertTrue(report.markdown().contains("NOT RUN"))
        XCTAssertEqual(try EvalReport.decode(report.json()).outcome, .notRun)
    }
}
