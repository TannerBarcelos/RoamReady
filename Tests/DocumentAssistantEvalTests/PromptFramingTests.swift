import XCTest
import CampCore
@testable import AssistantEval

final class PromptFramingTests: XCTestCase {
    func testEmptyRetrievalHasNoFramingInFullOrCompactPrompt() {
        for searched in [true, false] {
            let request = CampingHelpRequest(question: "How do I store drinking water?", steps: [], rigType: nil, step: nil,
                                             scope: .general, documents: DocumentEvidence(excerpts: [], searched: searched))
            for prompt in [request.prompt, request.compactPrompt] {
                XCTAssertNil(PromptFraming.failure(in: prompt, expectsEvidence: false, name: "prompt"))
            }
        }
    }

    func testRetrievedEvidenceHasOneFrameInFullAndCompactPrompt() {
        let id = UUID()
        let evidence = DocumentEvidence.make(question: "What does E4 mean?", candidates: [
            DocumentEvidenceCandidate(documentID: id, indexedChecksum: "v1", page: 2,
                                      text: "Error code E4 means the igniter failed to light.")
        ], live: [id: LiveDocument(id: id, title: "Water Heater Manual", category: "Manual", checksum: "v1", isInScope: true)])
        XCTAssertFalse(evidence.isEmpty)
        let request = CampingHelpRequest(question: "What does E4 mean?", steps: [], rigType: nil, step: nil,
                                         scope: .general, documents: evidence)
        for prompt in [request.prompt, request.compactPrompt] {
            XCTAssertNil(PromptFraming.failure(in: prompt, expectsEvidence: true, name: "prompt"))
        }
    }

    func testEmptyRetrievalRejectsUnexpectedFramesAndOrphanDelimiters() {
        for prompt in ["BEGIN DOCUMENT EXCERPTS", "END DOCUMENT EXCERPTS",
                       "BEGIN DOCUMENT EXCERPTS\nNo relevant excerpts were found.\nEND DOCUMENT EXCERPTS"] {
            XCTAssertNotNil(PromptFraming.failure(in: prompt, expectsEvidence: false, name: "prompt"), prompt)
        }
    }

    func testEvidenceRejectsMissingDuplicatedAndReversedDelimiters() {
        let begin = "BEGIN DOCUMENT EXCERPTS", end = "END DOCUMENT EXCERPTS"
        for prompt in ["", begin, end, "\(begin)\n\(begin)\n\(end)", "\(begin)\n\(end)\n\(end)", "\(end)\n\(begin)"] {
            XCTAssertNotNil(PromptFraming.failure(in: prompt, expectsEvidence: true, name: "prompt"), prompt)
        }
    }
}
