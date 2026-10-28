import XCTest
@testable import DocumentSearch

final class IndexReuseTests: XCTestCase {
    func testAPublishedDocumentIsReusedAfterReopenUntilItsFileOrRulesChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reuse-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var index = try DocumentSearchIndex(url: url)
        let doc = IndexedDocument(id: "d", checksum: "abc", extractionVersion: 1, chunkingVersion: PassageChunker.version, language: "en")
        try await index.publish(doc, passages: [IndexedPassage(text: "Error code E4 means the igniter failed.", page: 2)])
        await index.close()

        index = try DocumentSearchIndex(url: url)
        let record = try await index.indexedDocuments()["d"]
        XCTAssertEqual(record?.isCurrent(checksum: "abc", extractionVersion: 1), true)
        XCTAssertEqual(record?.isCurrent(checksum: "changed", extractionVersion: 1), false)
        XCTAssertEqual(record?.isCurrent(checksum: "abc", extractionVersion: 2), false)
        let hit = try await index.search("E4", documentIDs: ["d"]).hits.first
        XCTAssertEqual(hit?.page, 2, "the passages survived the relaunch")
    }

    func testAnOutdatedIndexFileIsRefusedSoItCanBeRebuilt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try SQLiteDatabase(path: url.path)
        try raw.run("PRAGMA user_version = 1")
        raw.close()
        XCTAssertThrowsError(try DocumentSearchIndex(url: url)) {
            XCTAssertEqual($0 as? DocumentSearchError, .outdatedSchema(1))
        }
    }
}
