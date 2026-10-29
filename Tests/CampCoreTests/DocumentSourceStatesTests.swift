import XCTest
@testable import CampCore

@MainActor
private final class OneReply: CampingResponseGenerating {
    let reply: String
    init(_ reply: String) { self.reply = reply }
    func respond(to prompt: String, instructions: String) async throws -> String { reply }
}

final class DocumentSourceStatesTests: XCTestCase {
    private func source(_ id: String = "S1", checksum: String = "c1") -> DocumentSource {
        DocumentSource(id: id, documentID: UUID(), checksum: checksum, title: "Manual", category: "Manual", page: 4)
    }

    // MARK: Availability when a source is tapped

    func testSameChecksumWithLocalBytesIsCurrent() {
        XCTAssertEqual(SourceResolution.availability(of: source(), live: LiveSourceDocument(checksum: "c1", hasLocalContent: true)), .current)
    }

    func testReplacedFileIsChangedEvenWhenBytesAreLocal() {
        XCTAssertEqual(SourceResolution.availability(of: source(), live: LiveSourceDocument(checksum: "c2", hasLocalContent: true)), .changed)
    }

    func testFileRemovedFromADocumentIsChanged() {
        XCTAssertEqual(SourceResolution.availability(of: source(), live: LiveSourceDocument(checksum: nil, hasLocalContent: false)), .changed)
    }

    func testMissingDocumentIsDeleted() {
        XCTAssertEqual(SourceResolution.availability(of: source(), live: nil), .deleted)
    }

    func testUnchangedFileThatHasNotDownloadedIsNotDownloaded() {
        XCTAssertEqual(SourceResolution.availability(of: source(), live: LiveSourceDocument(checksum: "c1", hasLocalContent: false)), .notDownloaded)
    }

    // MARK: Source sections

    func testCitedSourcesCarryNoNoteAndKeepSearchedReferencesSeparate() {
        let cited = source("S1"), searched = source("S2")
        let sections = AnswerSources(coverage: .cited, cited: [cited], searched: [searched])
        XCTAssertEqual(sections.cited, [cited])
        XCTAssertEqual(sections.searched, [searched])
        XCTAssertNil(sections.note)
    }

    func testUncitedAnswerExplainsItIsGeneralAdviceAndStillListsWhatWasSearched() {
        let sections = AnswerSources(coverage: .uncited, cited: [], searched: [source()])
        XCTAssertEqual(sections.note, .generalAdvice)
        XCTAssertEqual(sections.searched.count, 1)
        XCTAssertEqual(AnswerSources.text(for: .generalAdvice), "General advice. No document was cited.")
    }

    func testNothingRelevantAndNothingSearchedEachGetTheirOwnNote() {
        XCTAssertEqual(AnswerSources(coverage: .notCovered, cited: [], searched: []).note, .notCovered)
        XCTAssertEqual(AnswerSources(coverage: .notSearched, cited: [], searched: []).note, .noDocuments)
    }

    func testUnfinishedAnswerLeavesItsExplanationToTheReadinessNote() {
        XCTAssertNil(AnswerSources(coverage: .unfinished, cited: [], searched: []).note)
    }

    // MARK: Reply

    private func evidence() -> DocumentEvidence {
        let id = UUID()
        let live = LiveDocument(id: id, title: "Heater", category: "Manual", checksum: "c1", isInScope: true)
        let fault = "Error code E4 means the water heater igniter failed to light."
        let candidates = [1, 2].map {
            DocumentEvidenceCandidate(documentID: id, indexedChecksum: "c1", page: $0, text: "Page \($0). " + fault)
        }
        return DocumentEvidence.make(question: "error code E4", candidates: candidates, live: [id: live])
    }

    func testRepliesSplitCitedSourcesFromExcerptsTheModelWasGivenButDidNotCite() async throws {
        let request = CampingHelpRequest(question: "E4?", steps: [], rigType: nil, step: nil, scope: .general, documents: evidence())
        let reply = try await CampingGeneration.answer(to: request, using: OneReply("The igniter failed [S2]."))
        XCTAssertEqual(reply.sources.map(\.id), ["S2"])
        XCTAssertEqual(reply.searched.map(\.id), ["S1"])
    }

    func testUncitedReplyListsEverythingSuppliedAsSearched() async throws {
        let request = CampingHelpRequest(question: "E4?", steps: [], rigType: nil, step: nil, scope: .general, documents: evidence())
        let reply = try await CampingGeneration.answer(to: request, using: OneReply("Check the igniter."))
        XCTAssertEqual(reply.coverage, .uncited)
        XCTAssertTrue(reply.sources.isEmpty)
        XCTAssertEqual(reply.searched.map(\.id), ["S1", "S2"])
    }
}
