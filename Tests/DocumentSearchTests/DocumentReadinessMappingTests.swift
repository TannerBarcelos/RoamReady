import XCTest
import CampCore
@testable import DocumentSearch

final class DocumentReadinessMappingTests: XCTestCase {
    func testEveryIndexStateMapsToItsReadiness() {
        let pairs: [(DocumentIndexState, AssistantDocumentStatus)] = [
            (.queued, .queued), (.extracting, .extracting), (.indexing(done: 3, of: 9), .indexing(done: 3, of: 9)),
            (.ready, .ready), (.readPartially, .readPartially), (.waitingForDownload, .waitingForDownload),
            (.englishOnly, .englishOnly), (.englishPartial, .englishPartial), (.unsupported, .unsupported), (.retryableFailure, .retryableFailure),
            (.noUsableText(.empty), .noUsableText(.empty)), (.noUsableText(.encrypted), .noUsableText(.encrypted)),
            (.noUsableText(.unreadable), .noUsableText(.unreadable)), (.noUsableText(.tooLarge), .noUsableText(.tooLarge)),
            (.noUsableText(.noText), .noUsableText(.noText))
        ]
        for (state, readiness) in pairs { XCTAssertEqual(AssistantDocumentStatus(state), readiness) }
    }

    func testWaitingForDownloadStaysDistinctFromAFailure() {
        XCTAssertEqual(AssistantDocumentStatus(.waitingForDownload).nextAction, .wait)
        XCTAssertEqual(AssistantDocumentStatus(.retryableFailure).nextAction, .retry)
        XCTAssertEqual(AssistantDocumentStatus(.noUsableText(.noText)).nextAction, .replaceFile)
    }
}
