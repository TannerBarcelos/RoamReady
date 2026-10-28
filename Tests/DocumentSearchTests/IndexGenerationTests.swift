import XCTest
@testable import DocumentSearch

final class IndexGenerationTests: XCTestCase {
    private func temporaryURL(_ name: String = "index") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).sqlite")
    }

    private func document(_ id: String = "d", checksum: String) -> IndexedDocument {
        IndexedDocument(id: id, checksum: checksum, extractionVersion: 1, chunkingVersion: PassageChunker.version, language: "en")
    }

    private func texts(_ result: SearchResult) -> [String] { result.hits.map(\.text) }

    func testAStagedGenerationIsInvisibleAndTheOldOneKeepsItsOwnChecksum() async throws {
        let index = try DocumentSearchIndex(url: temporaryURL())
        try await index.publish(document(checksum: "old"), passages: [IndexedPassage(text: "Old igniter text for the heater.", page: 1)])

        let token = try await index.beginStaging(document(checksum: "new"))
        try await index.stage(token, passages: [IndexedPassage(text: "New igniter text for the heater.", page: 1)])

        // The library holds "new" now, so nothing indexed from "old" may answer, and the staged rows aren't live yet.
        let whileStaging = try await index.search("igniter", live: ["d": "new"])
        XCTAssertTrue(whileStaging.hits.isEmpty)
        let oldStillServesItsOwnChecksum = try await index.search("igniter", live: ["d": "old"])
        XCTAssertEqual(texts(oldStillServesItsOwnChecksum), ["Old igniter text for the heater."])

        try await index.commit(token)
        let afterCommit = try await index.search("igniter", live: ["d": "new"])
        XCTAssertEqual(texts(afterCommit), ["New igniter text for the heater."])
        let afterCommitOld = try await index.search("igniter", live: ["d": "old"])
        XCTAssertTrue(afterCommitOld.hits.isEmpty, "the superseded generation is gone")
    }

    func testACrashMidIndexLeavesTheOldGenerationAndNeverServesItAsCurrent() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var index = try DocumentSearchIndex(url: url)
        try await index.publish(document(checksum: "old"), passages: [IndexedPassage(text: "Old igniter text for the heater.", page: 1)])
        let token = try await index.beginStaging(document(checksum: "new"))
        try await index.stage(token, passages: [IndexedPassage(text: "New igniter text, first half.", page: 1)])
        await index.close() // the process dies here; nothing was committed

        index = try DocumentSearchIndex(url: url)
        XCTAssertEqual(index.abandonedStagingCount, 1)
        let record = try await index.indexedDocuments()["d"]
        XCTAssertEqual(record?.checksum, "old")
        XCTAssertEqual(record?.isCurrent(checksum: "new", extractionVersion: 1), false, "the new file still needs indexing")
        let current = try await index.search("igniter", live: ["d": "new"])
        XCTAssertTrue(current.hits.isEmpty)

        do {
            try await index.stage(token, passages: [IndexedPassage(text: "Late write from the dead run.", page: 2)])
            XCTFail("a token from before the restart must not write")
        } catch {
            XCTAssertEqual(error as? DocumentSearchError, .staleStaging)
        }

        // The retry publishes cleanly, and none of the abandoned rows come back.
        try await index.publish(document(checksum: "new"), passages: [IndexedPassage(text: "New igniter text, complete.", page: 1)])
        let republished = try await index.search("igniter", live: ["d": "new"])
        XCTAssertEqual(texts(republished), ["New igniter text, complete."])
    }

    func testBeginningAgainReplacesAnEarlierAttempt() async throws {
        let index = try DocumentSearchIndex(url: temporaryURL())
        let first = try await index.beginStaging(document(checksum: "v2"))
        try await index.stage(first, passages: [IndexedPassage(text: "First attempt text here.", page: 1)])
        let second = try await index.beginStaging(document(checksum: "v2"))
        do {
            try await index.commit(first)
            XCTFail("the replaced attempt can't commit")
        } catch {
            XCTAssertEqual(error as? DocumentSearchError, .staleStaging)
        }
        try await index.stage(second, passages: [IndexedPassage(text: "Second attempt text here.", page: 1)])
        try await index.commit(second)
        let result = try await index.search("attempt", live: ["d": "v2"])
        XCTAssertEqual(texts(result), ["Second attempt text here."])
    }

    func testOnlyDocumentsInTheLiveMapAtTheirLiveChecksumAreSearched() async throws {
        let index = try DocumentSearchIndex(url: temporaryURL())
        try await index.publish(document("kept", checksum: "k1"), passages: [IndexedPassage(text: "Shared warranty wording.", page: 1)])
        try await index.publish(document("deleted", checksum: "x1"), passages: [IndexedPassage(text: "Shared warranty wording.", page: 1)])
        try await index.publish(document("optedOut", checksum: "o1"), passages: [IndexedPassage(text: "Shared warranty wording.", page: 1)])

        // Stale rows for "deleted" and "optedOut" are still on disk; the library no longer lists them.
        let result = try await index.search("warranty", live: ["kept": "k1"])
        XCTAssertEqual(result.hits.map(\.documentID), ["kept"])
        let wrongChecksum = try await index.search("warranty", live: ["kept": "k2"])
        XCTAssertTrue(wrongChecksum.hits.isEmpty)
    }

    func testRemovingADocumentAlsoDropsItsUnfinishedGeneration() async throws {
        let index = try DocumentSearchIndex(url: temporaryURL())
        try await index.publish(document(checksum: "a"), passages: [IndexedPassage(text: "Visible passage text.", page: 1)])
        let token = try await index.beginStaging(document(checksum: "b"))
        try await index.stage(token, passages: [IndexedPassage(text: "Staged passage text.", page: 1)])
        try await index.remove(documentID: "d")
        let indexed = try await index.indexedDocuments()
        XCTAssertTrue(indexed.isEmpty)
        do {
            try await index.commit(token)
            XCTFail("nothing left to commit")
        } catch {
            XCTAssertEqual(error as? DocumentSearchError, .staleStaging)
        }
    }

    func testAnEmbeddingRevisionChangeRetiresVectorsWhileLexicalSearchKeepsWorking() async throws {
        let index = try DocumentSearchIndex(url: temporaryURL())
        let first = DeterministicEmbeddingProvider(revision: "rev-1")
        try await index.publish(document(checksum: "a"), passages: [IndexedPassage(text: "Drain the fresh water tank before winter.", page: 1)], embedding: first)
        let withVectors = try await index.search("winter drain", live: ["d": "a"], embedding: first)
        XCTAssertTrue(withVectors.usedVectors)

        let second = DeterministicEmbeddingProvider(revision: "rev-2")
        let whileStale = try await index.search("winter drain", live: ["d": "a"], embedding: second)
        XCTAssertFalse(whileStale.usedVectors, "rev-1 vectors are never compared with rev-2 queries")
        XCTAssertEqual(whileStale.hits.count, 1, "the lexical index still answers")

        let retired = try await index.retireIncompatibleVectors(keeping: second.profile)
        XCTAssertEqual(retired, ["d"])
        try await index.indexVectors(documentID: "d", embedding: second)
        let rebuilt = try await index.search("winter drain", live: ["d": "a"], embedding: second)
        XCTAssertTrue(rebuilt.usedVectors)
    }

    func testNonIndexableOutcomesAreRecordedSoTheyAreNotReadAgain() async throws {
        let index = try DocumentSearchIndex(url: temporaryURL())
        var scanned = document(checksum: "a")
        scanned.outcome = .noUsableText
        try await index.publish(scanned, passages: [])
        let record = try await index.indexedDocuments()["d"]
        XCTAssertEqual(record?.outcome, .noUsableText)
        XCTAssertEqual(record?.isCurrent(checksum: "a", extractionVersion: 1), true)
    }

    func testAGarbageFileIsReportedAsCorruption() throws {
        let url = temporaryURL("garbage")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("this is not a database, it just looks like a file".utf8).write(to: url)
        XCTAssertThrowsError(try DocumentSearchIndex(url: url, verifyIntegrity: true)) {
            XCTAssertEqual(($0 as? DocumentSearchError)?.isCorruption, true)
        }
    }

    func testDamagedPagesInsideARealIndexFailTheIntegrityCheck() async throws {
        let url = temporaryURL("damaged")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try DocumentSearchIndex(url: url)
        let passages = (0..<200).map { IndexedPassage(text: "Passage number \($0) about the furnace and the igniter.", page: $0 + 1) }
        try await index.publish(document(checksum: "a"), passages: passages)
        await index.close()

        var bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 20_000)
        for offset in stride(from: 8_192, to: bytes.count, by: 4_096) { bytes.replaceSubrange(offset..<offset + 64, with: Data(repeating: 0xFF, count: 64)) }
        try bytes.write(to: url)

        XCTAssertThrowsError(try DocumentSearchIndex(url: url, verifyIntegrity: true)) {
            XCTAssertEqual(($0 as? DocumentSearchError)?.isCorruption, true)
        }
    }
}
