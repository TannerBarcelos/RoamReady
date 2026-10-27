import XCTest
@testable import DocumentSearch

final class DocumentSearchIndexTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("search.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func document(_ id: String, checksum: String = "aaa", rig: String? = nil, trip: String? = nil) -> IndexedDocument {
        IndexedDocument(id: id, checksum: checksum, extractionVersion: 1, chunkingVersion: 1, language: "en", rigID: rig, tripID: trip)
    }

    private let manual = [
        IndexedPassage(text: "Torque the lug nuts to 110 ft-lb after the first 50 miles.", page: 12, section: "Wheels"),
        IndexedPassage(text: "Drain the fresh water tank before winter storage.", page: 31, section: "Winterizing"),
        IndexedPassage(text: "Error code E47 means the furnace igniter failed.", page: 40, section: "Troubleshooting")
    ]

    func testSqliteVecAndFTS5AreAvailable() {
        XCTAssertEqual(DocumentSearchIndex.sqliteVecVersion, "v0.1.9")
    }

    func testFileBackedLifecycleInsertQueryReopenDelete() async throws {
        let provider = DeterministicEmbeddingProvider()
        var index = try DocumentSearchIndex(url: fileURL)
        let readiness = try await index.publish(document("manual"), passages: manual, embedding: provider)
        XCTAssertEqual(readiness, DocumentReadiness(checksum: "aaa", lexicalReady: true, vectorReady: true))

        let lexical = try await index.search("lug nuts torque", documentIDs: ["manual"])
        XCTAssertEqual(lexical.hits.first?.page, 12)
        XCTAssertFalse(lexical.usedVectors)

        let both = try await index.search("lug nuts torque", documentIDs: ["manual"], embedding: provider)
        XCTAssertTrue(both.usedVectors)
        XCTAssertEqual(both.hits.first?.page, 12)
        XCTAssertEqual(both.hits.first.map { [$0.matchedLexically, $0.matchedByVector] }, [true, true])

        // Words the passage doesn't contain: only the vector side can't help either, so ask by shared words.
        let nearest = try await index.search("winter water tank storage", documentIDs: ["manual"], embedding: provider)
        XCTAssertEqual(nearest.hits.first?.section, "Winterizing")

        await index.close()
        index = try DocumentSearchIndex(url: fileURL)
        let reopened = try await index.search("furnace igniter E47", documentIDs: ["manual"], embedding: provider)
        XCTAssertEqual(reopened.hits.first?.page, 40)
        XCTAssertTrue(reopened.usedVectors)
        let reopenedReadiness = try await index.readiness(of: ["manual"], embedding: provider)
        XCTAssertEqual(reopenedReadiness["manual"]?.vectorReady, true)

        try await index.remove(documentID: "manual")
        let afterDelete = try await index.search("furnace igniter", documentIDs: ["manual"], embedding: provider)
        XCTAssertTrue(afterDelete.hits.isEmpty)
        let gone = try await index.readiness(of: ["manual"])
        XCTAssertTrue(gone.isEmpty)
    }

    func testUnavailableEmbeddingsFallBackToLexicalAndCatchUpLater() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        let offline = DeterministicEmbeddingProvider(isAvailable: false)
        let published = try await index.publish(document("manual"), passages: manual, embedding: offline)
        XCTAssertEqual(published, DocumentReadiness(checksum: "aaa", lexicalReady: true, vectorReady: false))

        let result = try await index.search("igniter", documentIDs: ["manual"], embedding: offline)
        XCTAssertEqual(result.hits.first?.page, 40)
        XCTAssertFalse(result.usedVectors)

        let online = DeterministicEmbeddingProvider()
        let indexed = try await index.indexVectors(documentID: "manual", embedding: online)
        XCTAssertTrue(indexed)
        let ready = try await index.readiness(of: ["manual"], embedding: online)
        XCTAssertEqual(ready["manual"]?.vectorReady, true)
    }

    func testChangingRevisionOrDimensionMakesOldVectorsIneligible() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        let v1 = DeterministicEmbeddingProvider(revision: "r1", dimension: 64)
        try await index.publish(document("manual"), passages: manual, embedding: v1)

        for changed in [DeterministicEmbeddingProvider(revision: "r2", dimension: 64),
                        DeterministicEmbeddingProvider(revision: "r1", dimension: 32)] {
            let ready = try await index.readiness(of: ["manual"], embedding: changed)
            XCTAssertEqual(ready["manual"]?.lexicalReady, true)
            XCTAssertEqual(ready["manual"]?.vectorReady, false)
            let result = try await index.search("igniter failed", documentIDs: ["manual"], embedding: changed)
            XCTAssertFalse(result.usedVectors, "old vectors must not be retrieved")
            XCTAssertEqual(result.hits.first?.page, 40, "lexical search keeps working")
        }

        let stale = try await index.retireIncompatibleVectors(keeping: EmbeddingProfile(revision: "r2", dimension: 64))
        XCTAssertEqual(stale, ["manual"])
        let reembedded = try await index.indexVectors(documentID: "manual", embedding: DeterministicEmbeddingProvider(revision: "r2", dimension: 64))
        XCTAssertTrue(reembedded)
        let after = try await index.search("igniter failed", documentIDs: ["manual"], embedding: DeterministicEmbeddingProvider(revision: "r2", dimension: 64))
        XCTAssertTrue(after.usedVectors)
        let old = try await index.readiness(of: ["manual"], embedding: v1)
        XCTAssertEqual(old["manual"]?.vectorReady, false)
    }

    func testScopeAllowListIsAppliedBeforeRanking() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        let provider = DeterministicEmbeddingProvider()
        // Out-of-scope documents match the question far better than the in-scope one.
        for number in 0..<20 {
            try await index.publish(document("other-\(number)"), passages: [IndexedPassage(text: "fridge fridge fridge error code")], embedding: provider)
        }
        try await index.publish(document("mine"), passages: [IndexedPassage(text: "Reset the fridge after an error by holding the button.")], embedding: provider)

        let scoped = try await index.search("fridge fridge error code", documentIDs: ["mine"], limit: 3, embedding: provider)
        XCTAssertEqual(scoped.hits.map(\.documentID), ["mine"])
        XCTAssertTrue(scoped.usedVectors)
        let lexicalOnly = try await index.search("fridge fridge error code", documentIDs: ["mine"], limit: 3)
        XCTAssertEqual(lexicalOnly.hits.map(\.documentID), ["mine"])

        let empty = try await index.search("fridge", documentIDs: [], embedding: provider)
        XCTAssertTrue(empty.hits.isEmpty)
    }

    func testRepublishReplacesTheOldChecksumAtomically() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        let provider = DeterministicEmbeddingProvider()
        try await index.publish(document("manual", checksum: "old"), passages: [IndexedPassage(text: "Legacy pressure is 30 psi.")], embedding: provider)
        let republished = try await index.publish(document("manual", checksum: "new"), passages: [IndexedPassage(text: "Pressure is 35 psi.")], embedding: provider)
        XCTAssertEqual(republished.checksum, "new")

        let old = try await index.search("legacy", documentIDs: ["manual"], embedding: provider)
        XCTAssertFalse(old.hits.contains { $0.text.contains("Legacy") })
        let current = try await index.search("pressure psi", documentIDs: ["manual"], embedding: provider)
        XCTAssertEqual(current.hits.map(\.text), ["Pressure is 35 psi."])
    }

    func testStaleRowsLeftBehindAreNeverServed() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        try await index.publish(document("manual", checksum: "new"), passages: [IndexedPassage(text: "Current torque 110.")])
        await index.close()

        // Simulate a crash that left a superseded generation's rows behind.
        let raw = try SQLiteDatabase(path: fileURL.path)
        try raw.run("INSERT INTO passages (doc_id, generation, ordinal, text) VALUES ('manual', 0, 0, 'Stale torque 90.')")
        try raw.run("INSERT INTO passages_fts (rowid, text) VALUES (last_insert_rowid(), 'Stale torque 90.')")
        raw.close()

        let reopened = try DocumentSearchIndex(url: fileURL)
        let result = try await reopened.search("torque", documentIDs: ["manual"])
        XCTAssertEqual(result.hits.map(\.text), ["Current torque 110."])
    }

    func testHostileInputNeitherErrorsNorInjects() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        let provider = DeterministicEmbeddingProvider()
        try await index.publish(document("manual"), passages: manual, embedding: provider)
        try await index.publish(document("secret"), passages: [IndexedPassage(text: "Hidden lug nuts secret")], embedding: provider)

        let hostile = [
            "\"", "\"\"\"", "lug AND", "OR OR", "NOT lug", "NEAR(lug nuts, 2)", "text:lug", "{text}: lug", "lug*", "^lug",
            "(((", ")", "lug' OR 1=1 --", "'; DROP TABLE passages; --", "-lug", "lug\0nuts", "col1:", "* *", "   ", "",
            "\u{202E}lug", String(repeating: "lug ", count: 500), String(repeating: "x", count: 10_000), "🚐 🏕️"
        ]
        for query in hostile {
            let result = try await index.search(query, documentIDs: ["manual"], embedding: provider)
            XCTAssertFalse(result.hits.contains { $0.documentID == "secret" }, "scope leaked for \(query.debugDescription)")
        }
        let still = try await index.search("lug nuts", documentIDs: ["manual"])
        XCTAssertEqual(still.hits.first?.page, 12)

        // A hostile document ID is only ever a bound value.
        let odd = try await index.search("lug", documentIDs: ["manual' OR '1'='1", "\"; DROP TABLE documents; --"])
        XCTAssertTrue(odd.hits.isEmpty)
        try await index.publish(document("x'); DROP TABLE documents; --"), passages: [IndexedPassage(text: "anchor point")])
        let anchored = try await index.search("anchor", documentIDs: ["x'); DROP TABLE documents; --"])
        XCTAssertEqual(anchored.hits.count, 1)
    }

    func testMatchExpressionQuotesEveryTerm() {
        XCTAssertEqual(FTSQuery.match(from: "lug AND nuts"), "\"lug\" OR \"AND\" OR \"nuts\"")
        XCTAssertEqual(FTSQuery.match(from: "say \"hi\""), "\"say\" OR \"\"\"hi\"\"\"")
        XCTAssertNil(FTSQuery.match(from: " ** \"\" "))
        XCTAssertEqual(FTSQuery.match(from: "E47"), "\"E47\"")
    }

    func testExactCodesSurviveSearch() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        try await index.publish(document("manual"), passages: manual)
        let result = try await index.search("E47", documentIDs: ["manual"])
        XCTAssertEqual(result.hits.first?.page, 40)
    }

    func testNewerSchemaIsRefusedRatherThanModified() async throws {
        let index = try DocumentSearchIndex(url: fileURL)
        await index.close()
        let raw = try SQLiteDatabase(path: fileURL.path)
        try raw.run("PRAGMA user_version = 99")
        raw.close()
        XCTAssertThrowsError(try DocumentSearchIndex(url: fileURL)) {
            XCTAssertEqual($0 as? DocumentSearchError, .newerSchema(99))
        }
    }

    func testMismatchedEmbeddingDimensionLeavesDocumentLexicalOnly() async throws {
        struct Liar: EmbeddingProvider {
            func availability() async -> EmbeddingAvailability { .available(EmbeddingProfile(revision: "x", dimension: 8)) }
            func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [1, 2, 3] } }
        }
        let index = try DocumentSearchIndex(url: fileURL)
        let readiness = try await index.publish(document("manual"), passages: manual, embedding: Liar())
        XCTAssertEqual(readiness.lexicalReady, true)
        XCTAssertEqual(readiness.vectorReady, false)
    }
}
