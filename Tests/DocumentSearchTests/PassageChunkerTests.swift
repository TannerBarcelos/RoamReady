import XCTest
@testable import DocumentSearch

final class PassageChunkerTests: XCTestCase {
    func testPassagesKeepOneBasedPageOrdinalsAndPrintedLabels() {
        let passages = PassageChunker.passages(from: [
            ExtractedPage(ordinal: 1, label: "i", text: "Welcome to your new trailer. Read this manual before travel."),
            ExtractedPage(ordinal: 2, label: "2", text: "Torque the lug nuts to 110 ft-lb after the first 50 miles.")
        ])
        XCTAssertEqual(passages.map(\.page), [1, 2])
        XCTAssertEqual(passages.map(\.pageLabel), ["i", nil], "a label equal to the ordinal adds nothing")
    }

    func testPassagesNeverCrossPagesAndStayBounded() {
        let sentence = "Check the propane regulator for cracks before every trip. "
        let pages = [ExtractedPage(ordinal: 1, text: String(repeating: sentence, count: 40)),
                     ExtractedPage(ordinal: 2, text: "Short note about the awning on the second page.")]
        let passages = PassageChunker.passages(from: pages)
        XCTAssertGreaterThan(passages.filter { $0.page == 1 }.count, 1)
        XCTAssertTrue(passages.allSatisfy { $0.text.count <= PassageChunker.maximumCharacters })
        XCTAssertEqual(passages.last?.page, 2)
        XCTAssertFalse(passages.last?.text.contains("propane") ?? true)
    }

    func testHeadingsStartPassagesAndNameTheirSectionAcrossPages() {
        let passages = PassageChunker.passages(from: [
            ExtractedPage(ordinal: 3, text: "TROUBLESHOOTING\nError code E47 means the furnace igniter failed.\nWINTERIZING\nDrain the fresh water tank before storage."),
            ExtractedPage(ordinal: 4, text: "Open every low point drain and leave the valves open.")
        ])
        XCTAssertEqual(passages.map(\.section), ["TROUBLESHOOTING", "WINTERIZING", "WINTERIZING"])
        XCTAssertTrue(passages[0].text.hasPrefix("TROUBLESHOOTING"))
        XCTAssertEqual(passages.map(\.page), [3, 3, 4])
    }

    func testEmptyAndImageOnlyPagesProduceNothing() {
        XCTAssertTrue(PassageChunker.passages(from: [ExtractedPage(ordinal: 1, text: ""), ExtractedPage(ordinal: 2, text: " \n \n")]).isEmpty)
    }

    func testHardWrappedLinesJoinIntoOneParagraph() {
        let passages = PassageChunker.passages(from: [ExtractedPage(ordinal: 1, text: "Turn the water heater off and\nwait five minutes before\nyou try to relight it again.")])
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].text, "Turn the water heater off and wait five minutes before you try to relight it again.")
    }

    func testPageLabelsRoundTripThroughTheIndex() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunker-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try DocumentSearchIndex(url: url)
        let doc = IndexedDocument(id: "d", checksum: "abc", extractionVersion: 1, chunkingVersion: PassageChunker.version, language: "en")
        try await index.publish(doc, passages: PassageChunker.passages(from: [ExtractedPage(ordinal: 7, label: "A-3", text: "The igniter failed on error E4.")]))
        let hit = try await index.search("igniter E4", documentIDs: ["d"]).hits.first
        XCTAssertEqual(hit?.page, 7)
        XCTAssertEqual(hit?.pageLabel, "A-3")
        XCTAssertEqual(hit?.checksum, "abc")
        let known = try await index.indexedDocuments()
        XCTAssertEqual(known["d"], IndexedDocumentRecord(checksum: "abc", extractionVersion: 1, chunkingVersion: PassageChunker.version))
    }
}
