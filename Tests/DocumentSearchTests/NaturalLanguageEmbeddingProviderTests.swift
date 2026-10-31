#if canImport(NaturalLanguage)
import XCTest
@testable import DocumentSearch

final class NaturalLanguageEmbeddingProviderTests: XCTestCase {
    func testAvailableAppleModelProducesUsableVectors() async throws {
        let provider = NaturalLanguageEmbeddingProvider()
        // Automated tests never download assets. Device acceptance explicitly runs prepare().
        guard case .available(let profile) = await provider.availability() else {
            throw XCTSkip("Apple embedding assets are not on this host; real-model validation was not run.")
        }
        let vectors = try await provider.embed(["Drain the fresh water tank before winter.", "What is the dinner menu?"])
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            XCTAssertEqual(vector.count, profile.dimension)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(vector.reduce(0) { $0 + $1 * $1 }, 0)
        }
        let after = await provider.availability()
        XCTAssertEqual(after, .available(profile), "A batch must stay in the same embedding space")
    }

    func testAvailableAppleModelPublishesVectorsThatSearchCanUse() async throws {
        let provider = NaturalLanguageEmbeddingProvider()
        guard case .available = await provider.availability() else {
            throw XCTSkip("Apple embedding assets are not on this host; real-index validation was not run.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apple-embeddings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try DocumentSearchIndex(url: folder.appendingPathComponent("search.sqlite"))
        let document = IndexedDocument(id: "manual", checksum: "c1", extractionVersion: 1,
                                       chunkingVersion: 1, language: "en")
        let readiness = try await index.publish(document, passages: [
            IndexedPassage(text: "Drain the fresh water tank before winter storage.", page: 1)
        ], embedding: provider)
        XCTAssertTrue(readiness.vectorReady)
        let result = try await index.search("water tank winter", live: ["manual": "c1"], embedding: provider)
        XCTAssertTrue(result.usedVectors)
        XCTAssertEqual(result.hits.first?.documentID, "manual")
        await index.close()
    }
}
#endif
