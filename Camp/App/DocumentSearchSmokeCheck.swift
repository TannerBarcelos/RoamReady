#if DEBUG
import Foundation
import DocumentSearch

/// `-document-search-smoke` proves, on the platform actually running, that the system SQLite has FTS5 and that
/// the statically linked sqlite-vec registers: a file-backed publish, lexical and nearest-neighbour search,
/// close and reopen, then delete. The index lives in a temporary folder, never next to the library.
enum DocumentSearchSmokeCheck {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-document-search-smoke") }

    static func runIfRequested() async {
        guard isRequested else { return }
        do {
            try await run()
            NSLog("DOCUMENT-SEARCH-SMOKE: PASS (sqlite-vec %@)", DocumentSearchIndex.sqliteVecVersion)
        } catch {
            NSLog("DOCUMENT-SEARCH-SMOKE: FAIL %@", "\(error)")
        }
    }

    private struct Failure: Error { var step: String }

    private static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentSearchSmoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("search.sqlite")
        let provider = DeterministicEmbeddingProvider()
        let document = IndexedDocument(id: "smoke", checksum: "smoke", extractionVersion: 1, chunkingVersion: 1, language: "en")
        let passages = [IndexedPassage(text: "Drain the fresh water tank before winter storage.", page: 3),
                        IndexedPassage(text: "Error code E47 means the furnace igniter failed.", page: 9)]

        var index = try DocumentSearchIndex(url: url)
        let readiness = try await index.publish(document, passages: passages, embedding: provider)
        guard readiness.lexicalReady, readiness.vectorReady else { throw Failure(step: "publish") }
        guard try await index.search("igniter", documentIDs: ["smoke"]).hits.first?.page == 9 else { throw Failure(step: "fts") }
        let nearest = try await index.search("winter water tank", documentIDs: ["smoke"], embedding: provider)
        guard nearest.usedVectors, nearest.hits.first?.page == 3 else { throw Failure(step: "knn") }

        await index.close()
        index = try DocumentSearchIndex(url: url)
        guard try await index.search("igniter", documentIDs: ["smoke"], embedding: provider).usedVectors else { throw Failure(step: "reopen") }
        try await index.remove(documentID: "smoke")
        guard try await index.search("igniter", documentIDs: ["smoke"], embedding: provider).hits.isEmpty else { throw Failure(step: "delete") }
        await index.close()
    }
}
#endif
