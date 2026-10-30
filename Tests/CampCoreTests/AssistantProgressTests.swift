import XCTest
@testable import CampCore

final class AssistantProgressTests: XCTestCase {
    func testOnlyReportedStagesAppearInOrder() {
        var progress = AssistantProgress()
        let id = progress.begin(question: "Why is E4 showing?")
        XCTAssertTrue(progress.stages.isEmpty)
        XCTAssertEqual(progress.advance(to: .searchingDocuments, for: id), "Searching your documents")
        XCTAssertEqual(progress.advance(to: .writing, for: id), "Writing an answer")
        XCTAssertEqual(progress.stages, [.searchingDocuments, .writing])
        XCTAssertEqual(progress.currentStage, .writing)
    }

    func testSearchStageIsOnlyPresentWhenReported() {
        var progress = AssistantProgress()
        let id = progress.begin(question: "q")
        progress.advance(to: .writing, for: id)
        XCTAssertEqual(progress.stages, [.writing], "no search stage when no documents were searched")
    }

    func testRepeatedStageIsNotAnnouncedTwice() {
        var progress = AssistantProgress()
        let id = progress.begin(question: "q")
        XCTAssertNotNil(progress.advance(to: .writing, for: id))
        XCTAssertNil(progress.advance(to: .writing, for: id))
    }

    func testStageTitlesAreShortAndPlain() {
        XCTAssertEqual(AssistantStage.searchingDocuments.title, "Searching your documents…")
        XCTAssertEqual(AssistantStage.writing.title, "Writing an answer…")
    }

    func testSecondQuestionIsNeverOverwrittenByTheFirst() {
        var progress = AssistantProgress()
        let first = progress.begin(question: "first")
        let second = progress.begin(question: "second")
        XCTAssertNil(progress.advance(to: .writing, for: first))
        XCTAssertFalse(progress.finish(first))
        XCTAssertNil(progress.fail(first, with: .failed))
        XCTAssertTrue(progress.isCurrent(second))
        XCTAssertEqual(progress.question, "second")
        XCTAssertTrue(progress.stages.isEmpty)
        XCTAssertTrue(progress.finish(second))
        XCTAssertFalse(progress.isActive)
    }

    func testCancelInvalidatesRunningWork() {
        var progress = AssistantProgress()
        let id = progress.begin(question: "q")
        progress.cancel()
        XCTAssertFalse(progress.isCurrent(id))
        XCTAssertNil(progress.advance(to: .writing, for: id))
        XCTAssertFalse(progress.finish(id))
        XCTAssertNil(progress.fail(id, with: .busy))
        XCTAssertNil(progress.failure)
        XCTAssertFalse(progress.isActive)
    }

    func testFailureClearsStagesAndIsAnnounced() {
        var progress = AssistantProgress()
        let id = progress.begin(question: "q")
        progress.advance(to: .writing, for: id)
        let text = progress.fail(id, with: .busy)
        XCTAssertEqual(progress.failure, .busy)
        XCTAssertTrue(progress.stages.isEmpty)
        XCTAssertFalse(progress.isActive)
        XCTAssertTrue(text?.hasPrefix("Couldn’t get a response.") == true)
    }

    func testBeginningAgainClearsEarlierFailure() {
        var progress = AssistantProgress()
        let id = progress.begin(question: "q")
        _ = progress.fail(id, with: .failed)
        _ = progress.begin(question: "q")
        XCTAssertNil(progress.failure)
    }
}
