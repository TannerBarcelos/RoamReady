import XCTest
@testable import DocumentSearch

/// Recognition confidence travels from the page to the passage to the search hit.
final class OCRProvenanceTests: XCTestCase {
    func testPassagesInheritTheirPagesConfidenceAndTextLayersHaveNone() {
        let passages = PassageChunker.passages(from: [
            ExtractedPage(ordinal: 1, text: "Torque the lug nuts to 110 ft-lb after the first fifty miles."),
            ExtractedPage(ordinal: 2, text: "Torque the lug nuts to 11O ft-lb after the first fifty miles.", ocrConfidence: 0.41)
        ])
        XCTAssertEqual(passages.map(\.page), [1, 2])
        XCTAssertNil(passages[0].ocrConfidence)
        XCTAssertEqual(passages[1].ocrConfidence, 0.41)
    }

    func testARecognizedTableRowIsNotMistakenForAHeading() {
        let passages = PassageChunker.passages(from: [
            ExtractedPage(ordinal: 1, text: "Tire Pressure\nFront Axle | 35 psi\nRear Axle | 40 psi", ocrConfidence: 0.9)
        ])
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].section, "Tire Pressure")
        XCTAssertTrue(passages[0].text.contains("Front Axle | 35 psi"))
    }

    func testConfidenceSurvivesTheIndex() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try DocumentSearchIndex(url: url)
        let document = IndexedDocument(id: "scan", checksum: "c", extractionVersion: 2,
                                       chunkingVersion: PassageChunker.version, language: "en")
        try await index.publish(document, passages: [
            IndexedPassage(text: "Torque the lug nuts to 110 ft-lb.", page: 2, ocrConfidence: 0.42),
            IndexedPassage(text: "Typed warranty terms last twelve months.", page: 3)
        ])
        let hits = try await index.search("lug nuts torque", documentIDs: ["scan"]).hits
        XCTAssertEqual(hits.first?.ocrConfidence, 0.42)
        let typed = try await index.search("warranty terms", documentIDs: ["scan"]).hits
        XCTAssertNil(typed.first?.ocrConfidence)
    }

    func testAnIndexFileFromBeforeRecognitionIsRefusedSoItIsRebuilt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v2-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SQLiteDatabase(path: url.path)
        try raw.run("PRAGMA user_version = 2")
        raw.close()
        XCTAssertThrowsError(try DocumentSearchIndex(url: url)) { XCTAssertEqual($0 as? DocumentSearchError, .outdatedSchema(2)) }
    }
}
