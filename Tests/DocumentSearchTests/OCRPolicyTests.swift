import XCTest
@testable import DocumentSearch

final class OCRPolicyTests: XCTestCase {
    // MARK: Which pages need recognition

    func testAPageWithRealTextHasAUsableLayer() {
        XCTAssertTrue(OCRPolicy.hasUsableTextLayer("Drain the fresh water tank before winter storage."))
    }

    func testAScanWithOnlyAPageNumberOrNothingHasNoUsableLayer() {
        XCTAssertFalse(OCRPolicy.hasUsableTextLayer(""))
        XCTAssertFalse(OCRPolicy.hasUsableTextLayer("  \n 12 \n"))
        XCTAssertFalse(OCRPolicy.hasUsableTextLayer("Page 3 of 40"))
    }

    func testABrokenFontEncodingIsNotAUsableLayer() {
        let garbled = String(repeating: "\u{FFFD}\u{FFFD}a1", count: 20)
        XCTAssertFalse(OCRPolicy.hasUsableTextLayer(garbled))
    }

    // MARK: Bounded rendering

    func testRenderSizeStaysWithinTheEdgeAndPixelCaps() {
        for (w, h) in [(612.0, 792.0), (14_400.0, 14_400.0), (50_000.0, 100.0), (100.0, 50_000.0), (0.5, 0.5), (3_000.0, 3_000.0)] {
            let size = OCRPolicy.renderSize(width: w, height: h)
            XCTAssertLessThanOrEqual(max(size.width, size.height), OCRPolicy.maximumRenderEdge, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(size.width * size.height, OCRPolicy.maximumRenderPixels, "\(w)x\(h)")
            XCTAssertGreaterThanOrEqual(min(size.width, size.height), 1)
        }
    }

    func testASmallPageIsNotBlownUpBeyondTheScaleCap() {
        let size = OCRPolicy.renderSize(width: 200, height: 100)
        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 300)
    }

    func testNonsenseSizesDoNotCrash() {
        XCTAssertEqual(OCRPolicy.renderSize(width: .nan, height: 10).width, 1)
        XCTAssertEqual(OCRPolicy.renderSize(width: -4, height: 10).width, 1)
        XCTAssertEqual(OCRPolicy.renderSize(width: .infinity, height: 10).width, 1)
    }

    func testImagesBeyondTheDecodeCapAreRefused() {
        XCTAssertTrue(OCRPolicy.isDecodable(pixelWidth: 8_000, pixelHeight: 6_000))
        XCTAssertFalse(OCRPolicy.isDecodable(pixelWidth: 20_000, pixelHeight: 20_000))
        XCTAssertFalse(OCRPolicy.isDecodable(pixelWidth: Int.max, pixelHeight: 2))
        XCTAssertFalse(OCRPolicy.isDecodable(pixelWidth: 0, pixelHeight: 10))
    }

    // MARK: The work budget

    func testBudgetStopsAtThePageCap() {
        var budget = OCRBudget(pages: 2, timeLimit: .seconds(10))
        XCTAssertTrue(budget.admit(elapsed: .zero))
        XCTAssertTrue(budget.admit(elapsed: .seconds(1)))
        XCTAssertFalse(budget.admit(elapsed: .seconds(1)))
    }

    func testBudgetStopsAtTheTimeCap() {
        var budget = OCRBudget(pages: 50, timeLimit: .seconds(10))
        XCTAssertTrue(budget.admit(elapsed: .seconds(9)))
        XCTAssertFalse(budget.admit(elapsed: .seconds(10)))
        XCTAssertEqual(budget.pagesRemaining, 49)
    }

    // MARK: Rotation

    func testAThinOrUnsureReadingTriesOtherRotationsButAConfidentOneDoesNot() {
        let sideways = RecognizedPage(text: "x7 q", confidence: 0.3)
        let upright = RecognizedPage(text: String(repeating: "Drain the tank before storage. ", count: 4), confidence: 0.95)
        XCTAssertTrue(OCRPolicy.shouldTryOtherRotations(sideways))
        XCTAssertFalse(OCRPolicy.shouldTryOtherRotations(upright))
        XCTAssertTrue(OCRPolicy.shouldTryOtherRotations(RecognizedPage(text: "", confidence: nil)))
    }

    func testTheBestReadingWinsAndATieKeepsTheUprightOne() {
        let upright = RecognizedPage(text: "garbled xq zv", confidence: 0.4)
        let turned = RecognizedPage(text: "Torque the lug nuts to 110 ft-lb", confidence: 0.92)
        XCTAssertEqual(OCRPolicy.best(of: [upright, turned]), turned)
        let same = RecognizedPage(text: "same words here", confidence: 0.8)
        let other = RecognizedPage(text: "same words here too", confidence: 0.8)
        XCTAssertEqual(OCRPolicy.best(of: [same, other]), same, "a turned reading that is only slightly better is not taken")
        XCTAssertNil(OCRPolicy.best(of: []))
    }

    // MARK: Layout

    private func line(_ text: String, x: Double, y: Double, width: Double = 0.2, confidence: Double = 0.9) -> RecognizedLine {
        RecognizedLine(text: text, confidence: confidence, x: x, y: y, width: width, height: 0.02)
    }

    func testLinesComeBackTopToBottom() {
        let page = OCRPolicy.page(from: [line("Second line of the page", x: 0.1, y: 0.5, width: 0.6),
                                         line("First line of the page", x: 0.1, y: 0.8, width: 0.6)])
        XCTAssertEqual(page.text, "First line of the page\nSecond line of the page")
    }

    func testTableCellsOnOneRowStayTogetherSoTheValueKeepsItsLabel() {
        let page = OCRPolicy.page(from: [
            line("Tire", x: 0.1, y: 0.80), line("Pressure", x: 0.5, y: 0.801),
            line("Front", x: 0.1, y: 0.70), line("35 psi", x: 0.5, y: 0.699),
            line("Rear", x: 0.1, y: 0.60), line("40 psi", x: 0.5, y: 0.601)
        ])
        XCTAssertEqual(page.text, "Tire | Pressure\nFront | 35 psi\nRear | 40 psi")
    }

    func testLongLinesOnTheSameRowAreProseColumnsAndAreNotSplicedTogether() {
        let page = OCRPolicy.page(from: [
            line("Left column sentence one continues here", x: 0.05, y: 0.8, width: 0.4),
            line("Right column sentence one continues here", x: 0.55, y: 0.8, width: 0.4)
        ])
        XCTAssertFalse(page.text.contains("|"))
        XCTAssertEqual(page.text.split(separator: "\n").count, 2)
    }

    func testConfidenceIsLengthWeightedAndNoiseLinesAreDropped() {
        let page = OCRPolicy.page(from: [
            line("A long and confidently read line", x: 0.1, y: 0.8, width: 0.6, confidence: 1.0),
            line("ab", x: 0.1, y: 0.7, width: 0.1, confidence: 0.5),
            line("x9#", x: 0.1, y: 0.6, width: 0.1, confidence: 0.1)
        ])
        XCTAssertFalse(page.text.contains("x9#"))
        let expected = (1.0 * 32 + 0.5 * 2) / 34
        XCTAssertEqual(page.confidence ?? 0, expected, accuracy: 0.001)
    }

    func testNothingRecognizedHasNoConfidence() {
        XCTAssertEqual(OCRPolicy.page(from: []), RecognizedPage(text: "", confidence: nil))
        XCTAssertEqual(OCRPolicy.page(from: [line("---", x: 0, y: 0)]).confidence, nil)
    }
}
