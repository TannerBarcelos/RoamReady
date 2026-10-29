import Foundation
import CSQLiteVec

/// What reading a document yielded. A document with nothing to search is still recorded, so it is not read
/// again until its file or the extraction rules change.
public enum IndexOutcome: Equatable, Sendable {
    case ready
    /// Some pages were left unread because a recognition cap was reached.
    case readPartially
    /// No passage is confidently English, so nothing is searched.
    case englishOnly
    /// Only the confidently English passages are searched; the rest are another language or unclassified.
    case englishPartial
    case noUsableText(NoUsableTextReason)

    var storageValue: String {
        switch self {
        case .ready: "ready"
        case .readPartially: "readPartially"
        case .englishOnly: "englishOnly"
        case .englishPartial: "englishPartial"
        case .noUsableText(.empty): "noUsableText:empty"
        case .noUsableText(.encrypted): "noUsableText:encrypted"
        case .noUsableText(.unreadable): "noUsableText:unreadable"
        case .noUsableText(.tooLarge): "noUsableText:tooLarge"
        case .noUsableText(.noText): "noUsableText:noText"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "readPartially": self = .readPartially
        case "englishOnly": self = .englishOnly
        case "englishPartial": self = .englishPartial
        case "noUsableText:empty": self = .noUsableText(.empty)
        case "noUsableText:encrypted": self = .noUsableText(.encrypted)
        case "noUsableText:unreadable": self = .noUsableText(.unreadable)
        case "noUsableText:tooLarge": self = .noUsableText(.tooLarge)
        case "noUsableText:noText", "noUsableText": self = .noUsableText(.noText)
        default: self = .ready
        }
    }
}

/// What the index records about one document snapshot. A new checksum, extraction version, or chunking
/// version is a new generation: callers publish again and the old rows are replaced in one step.
public struct IndexedDocument: Equatable, Sendable {
    public var id: String
    /// Checksum of the original file the passages came from.
    public var checksum: String
    public var extractionVersion: Int
    public var chunkingVersion: Int
    public var language: String
    public var rigID: String?
    public var tripID: String?
    public var outcome: IndexOutcome

    public init(id: String, checksum: String, extractionVersion: Int, chunkingVersion: Int, language: String,
                rigID: String? = nil, tripID: String? = nil, outcome: IndexOutcome = .ready) {
        self.outcome = outcome
        self.id = id
        self.checksum = checksum
        self.extractionVersion = extractionVersion
        self.chunkingVersion = chunkingVersion
        self.language = language
        self.rigID = rigID
        self.tripID = tripID
    }
}

/// A generation being built for one document. Only the index that issued it can commit it.
public struct StagingToken: Equatable, Sendable {
    public let documentID: String
    let generation: Int64
}

/// What the index remembers about a published document.
public struct IndexedDocumentRecord: Equatable, Sendable {
    public var checksum: String
    public var extractionVersion: Int
    public var chunkingVersion: Int
    public var outcome: IndexOutcome

    init(checksum: String, extractionVersion: Int, chunkingVersion: Int, outcome: IndexOutcome = .ready) {
        self.checksum = checksum
        self.extractionVersion = extractionVersion
        self.chunkingVersion = chunkingVersion
        self.outcome = outcome
    }

    /// Whether the stored passages still describe this file under the current rules, so the document can be
    /// used as it is, without reading it again.
    public func isCurrent(checksum: String, extractionVersion: Int) -> Bool {
        self.checksum == checksum && self.extractionVersion == extractionVersion && chunkingVersion == PassageChunker.version
    }
}

public struct IndexedPassage: Equatable, Sendable {
    public var text: String
    /// One-based page ordinal in the file, the number a viewer jumps to.
    public var page: Int?
    /// The label printed on the page ("iv", "A-3"), when it differs from the ordinal.
    public var pageLabel: String?
    public var section: String?
    /// Provenance: how sure text recognition was of this passage's page, 0...1. Nil when the text came from
    /// the file's own text layer, which is exact.
    public var ocrConfidence: Double?

    public init(text: String, page: Int? = nil, section: String? = nil, pageLabel: String? = nil, ocrConfidence: Double? = nil) {
        self.text = text
        self.page = page
        self.pageLabel = pageLabel
        self.section = section
        self.ocrConfidence = ocrConfidence
    }
}

public struct SearchHit: Equatable, Sendable {
    public var passageID: Int64
    public var documentID: String
    /// Checksum of the original file this passage was indexed from.
    public var checksum: String
    public var ordinal: Int
    public var page: Int?
    public var pageLabel: String?
    public var section: String?
    public var text: String
    /// Recognition confidence of the page this passage was read from; nil for a text layer.
    public var ocrConfidence: Double?
    /// Fused rank score; higher is better.
    public var score: Double
    public var matchedLexically: Bool
    public var matchedByVector: Bool
}

public struct SearchResult: Equatable, Sendable {
    public var hits: [SearchHit]
    /// False when the lexical index answered alone (no provider, unavailable, or no compatible vectors).
    public var usedVectors: Bool
}

public struct DocumentReadiness: Equatable, Sendable {
    public var checksum: String
    public var lexicalReady: Bool
    /// True only when the stored vectors match the provider's current revision and dimension.
    public var vectorReady: Bool
}

/// The Assistant's document search index: one disposable SQLite file with FTS5 and sqlite-vec. It never
/// touches SwiftData's store, and everything in it can be rebuilt from the documents, so a file that can't
/// be opened may simply be deleted.
public actor DocumentSearchIndex {
    public static let schemaVersion = 5
    /// The vendored sqlite-vec release, for diagnostics.
    public static var sqliteVecVersion: String { String(cString: csqlitevec_version()) }

    private static let embeddingBatchSize = 64

    private let database: SQLiteDatabase
    /// Unfinished generations a previous run left behind, discarded when this index opened.
    public nonisolated let abandonedStagingCount: Int

    /// With `verifyIntegrity`, SQLite's own consistency check runs first and a damaged file throws a corruption
    /// error, so the caller can delete it and index again.
    public init(url: URL, verifyIntegrity: Bool = false) throws {
        database = try SQLiteDatabase(path: url.path)
        try Self.prepareSchema(database)
        if verifyIntegrity, try database.query("PRAGMA quick_check(1)", [], { $0.text(0) }).first != "ok" {
            throw DocumentSearchError.sqlite(code: 11, message: "The index failed its integrity check.")
        }
        abandonedStagingCount = try Self.discardAbandonedStaging(database)
    }

    public func close() { database.close() }

    // MARK: Publishing

    /// Replaces everything indexed for `document.id` with these passages, then embeds them if a provider is
    /// available. A convenience over `beginStaging`, `stage`, and `commit` for callers with all passages at hand.
    @discardableResult
    public func publish(_ document: IndexedDocument, passages: [IndexedPassage],
                        embedding provider: EmbeddingProvider? = nil) async throws -> DocumentReadiness {
        let token = try beginStaging(document)
        do {
            try stage(token, passages: passages)
            return try await commit(token, embedding: provider)
        } catch {
            try? abandon(token)
            throw error
        }
    }

    // MARK: Staged generations

    /// Starts a new generation for a document. Nothing staged is visible to search, and the document's current
    /// generation keeps serving (under its own checksum) until `commit`. Starting again for the same document
    /// discards the earlier attempt.
    public func beginStaging(_ document: IndexedDocument) throws -> StagingToken {
        try database.transaction {
            try discardStaging(for: document.id)
            let generation = try nextGeneration()
            try database.run("""
                INSERT INTO staging (doc_id, generation, checksum, extraction_version, chunking_version, language,
                                     rig_id, trip_id, outcome, passage_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """, [.text(document.id), .int(generation), .text(document.checksum), .int(Int64(document.extractionVersion)),
                      .int(Int64(document.chunkingVersion)), .text(document.language),
                      document.rigID.map(Value.text) ?? .null, document.tripID.map(Value.text) ?? .null,
                      .text(document.outcome.storageValue)])
            return StagingToken(documentID: document.id, generation: generation)
        }
    }

    /// Appends passages to a staged generation, in order. Each call is its own short transaction, so a caller
    /// can checkpoint between batches. Throws `staleStaging` if the generation was replaced or abandoned.
    public func stage(_ token: StagingToken, passages: [IndexedPassage]) throws {
        try database.transaction {
            guard let count = try database.scalarInt("SELECT passage_count FROM staging WHERE doc_id = ? AND generation = ?",
                                                     [.text(token.documentID), .int(token.generation)])
            else { throw DocumentSearchError.staleStaging }
            for (offset, passage) in passages.enumerated() {
                try database.run("INSERT INTO passages (doc_id, generation, ordinal, page, page_label, section, text, ocr_confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                 [.text(token.documentID), .int(token.generation), .int(count + Int64(offset)),
                                  passage.page.map { Value.int(Int64($0)) } ?? .null,
                                  passage.pageLabel.map(Value.text) ?? .null,
                                  passage.section.map(Value.text) ?? .null, .text(passage.text),
                                  passage.ocrConfidence.map(Value.real) ?? .null])
                try database.run("INSERT INTO passages_fts (rowid, text) VALUES (last_insert_rowid(), ?)", [.text(passage.text)])
            }
            try database.run("UPDATE staging SET passage_count = ? WHERE doc_id = ? AND generation = ?",
                             [.int(count + Int64(passages.count)), .text(token.documentID), .int(token.generation)])
        }
    }

    /// Publishes a staged generation: in one transaction the document's previous generation is removed and the
    /// staged one becomes current. The lexical index is ready as soon as this commits, so a provider that is
    /// unavailable or failing leaves a document that FTS can still find.
    @discardableResult
    public func commit(_ token: StagingToken, embedding provider: EmbeddingProvider? = nil) async throws -> DocumentReadiness {
        let checksum: String = try database.transaction {
            let staged = try database.query("""
                SELECT checksum, extraction_version, chunking_version, language, rig_id, trip_id, outcome
                FROM staging WHERE doc_id = ? AND generation = ?
                """, [.text(token.documentID), .int(token.generation)]) { row in
                (row.text(0), row.int(1), row.int(2), row.text(3), row.optionalText(4), row.optionalText(5), row.text(6))
            }
            guard let staged = staged.first else { throw DocumentSearchError.staleStaging }
            try removeRows(for: token.documentID, keeping: token.generation)
            try database.run("""
                INSERT INTO documents (doc_id, generation, checksum, extraction_version, chunking_version, language,
                                       rig_id, trip_id, lexical_ready, vector_ready, outcome)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?)
                """, [.text(token.documentID), .int(token.generation), .text(staged.0), .int(staged.1), .int(staged.2),
                      .text(staged.3), staged.4.map(Value.text) ?? .null, staged.5.map(Value.text) ?? .null, .text(staged.6)])
            try database.run("DELETE FROM staging WHERE doc_id = ?", [.text(token.documentID)])
            return staged.0
        }
        if let provider { _ = try? await indexVectors(documentID: token.documentID, embedding: provider) }
        var profile: EmbeddingProfile?
        if let provider, case .available(let current) = await provider.availability() { profile = current }
        return try readiness(of: [token.documentID], profile: profile).first?.value
            ?? DocumentReadiness(checksum: checksum, lexicalReady: false, vectorReady: false)
    }

    /// Throws away a staged generation that won't be committed. The current generation is untouched.
    public func abandon(_ token: StagingToken) throws {
        try database.transaction {
            guard try database.scalarInt("SELECT 1 FROM staging WHERE doc_id = ? AND generation = ?",
                                         [.text(token.documentID), .int(token.generation)]) != nil else { return }
            try discardStaging(for: token.documentID)
        }
    }

    /// Embeds a published document's passages. Returns false when the provider is unavailable, the document
    /// is gone or was republished meanwhile, or the vectors don't fit the provider's declared dimension.
    /// Safe to call again later to catch up.
    @discardableResult
    public func indexVectors(documentID: String, embedding provider: EmbeddingProvider) async throws -> Bool {
        guard case .available(let profile) = await provider.availability(), Self.isUsable(profile),
              let generation = try database.scalarInt("SELECT generation FROM documents WHERE doc_id = ?", [.text(documentID)])
        else { return false }
        let passages = try database.query("SELECT id, text FROM passages WHERE doc_id = ? AND generation = ? ORDER BY ordinal",
                                          [.text(documentID), .int(generation)]) { ($0.int(0), $0.text(1)) }
        var vectors: [[Float]] = []
        let texts = passages.map(\.1)
        for start in stride(from: 0, to: texts.count, by: Self.embeddingBatchSize) {
            try Task.checkCancellation()
            vectors += try await provider.embed(Array(texts[start..<min(start + Self.embeddingBatchSize, texts.count)]))
        }
        guard vectors.count == passages.count, vectors.allSatisfy({ $0.count == profile.dimension }) else { return false }
        // The actor may have interleaved a republish while the provider ran.
        return try database.transaction {
            guard try database.scalarInt("SELECT generation FROM documents WHERE doc_id = ?", [.text(documentID)]) == generation
            else { return false }
            try removeVectors(for: documentID)
            let table = Self.vectorTable(profile.dimension)
            try database.run("CREATE VIRTUAL TABLE IF NOT EXISTS \(table) USING vec0(embedding float[\(profile.dimension)] distance_metric=cosine)")
            for (passage, vector) in zip(passages, vectors) {
                try database.run("INSERT INTO \(table) (rowid, embedding) VALUES (?, ?)", [.int(passage.0), .blob(Self.blob(vector))])
            }
            try database.run("UPDATE documents SET vector_ready = 1, embedding_revision = ?, embedding_dimension = ? WHERE doc_id = ?",
                             [.text(profile.revision), .int(Int64(profile.dimension)), .text(documentID)])
            return true
        }
    }

    /// Drops the vectors of every document embedded under a different revision or dimension and marks them
    /// vector-pending. Returns their IDs so the caller can re-embed. Lexical search is unaffected.
    @discardableResult
    public func retireIncompatibleVectors(keeping profile: EmbeddingProfile) throws -> [String] {
        let stale = try database.query("""
            SELECT doc_id FROM documents WHERE vector_ready = 1
              AND (embedding_revision IS NOT ? OR embedding_dimension IS NOT ?)
            """, [.text(profile.revision), .int(Int64(profile.dimension))]) { $0.text(0) }
        try database.transaction {
            for id in stale { try removeVectors(for: id) }
        }
        return stale
    }

    /// Every published document and the checksum it was indexed from, so a caller can tell what is missing,
    /// superseded, or no longer in the library.
    public func indexedDocuments() throws -> [String: IndexedDocumentRecord] {
        Dictionary(uniqueKeysWithValues: try database.query("SELECT doc_id, checksum, extraction_version, chunking_version, outcome FROM documents") {
            ($0.text(0), IndexedDocumentRecord(checksum: $0.text(1), extractionVersion: Int($0.int(2)), chunkingVersion: Int($0.int(3)),
                                               outcome: IndexOutcome(storageValue: $0.text(4))))
        })
    }

    public func remove(documentID: String) throws {
        try database.transaction {
            try removeRows(for: documentID)
            try discardStaging(for: documentID)
        }
    }

    // MARK: Searching

    /// Ranked passages from the documents in `documentIDs`, whatever generation of each is current. The
    /// allow-list is part of candidate selection in both the lexical and the vector query, so a passage that
    /// is only relevant globally never crowds out in-scope ones.
    public func search(_ question: String, documentIDs: Set<String>, limit: Int = 8,
                       embedding provider: EmbeddingProvider? = nil) async throws -> SearchResult {
        let current = try indexedDocuments()
        return try await search(question, live: Dictionary(uniqueKeysWithValues: documentIDs.compactMap { id in
            current[id].map { (id, $0.checksum) }
        }), limit: limit, embedding: provider)
    }

    /// Ranked passages from the documents in `live`, which maps each document ID to the checksum the library
    /// holds now. A document indexed from any other checksum is a superseded generation and is not searched,
    /// so a replaced file is never answered from while its new version is still being read.
    public func search(_ question: String, live: [String: String], limit: Int = 8,
                       embedding provider: EmbeddingProvider? = nil) async throws -> SearchResult {
        guard limit > 0, !live.isEmpty else { return SearchResult(hits: [], usedVectors: false) }
        let allowList = try Self.json(live)
        let candidates = limit * 4
        let lexical = try lexicalCandidates(question, allowList: allowList, limit: candidates)

        var vector: [SearchHit] = []
        var usedVectors = false
        if let provider, case .available(let profile) = await provider.availability(), Self.isUsable(profile),
           !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let query = try? await provider.embed([question]).first, query.count == profile.dimension {
            vector = try vectorCandidates(query, profile: profile, allowList: allowList, limit: candidates)
            usedVectors = !vector.isEmpty
        }
        return SearchResult(hits: Self.fuse(lexical: lexical, vector: vector, limit: limit), usedVectors: usedVectors)
    }

    public func readiness(of documentIDs: Set<String>, embedding provider: EmbeddingProvider? = nil) async throws -> [String: DocumentReadiness] {
        var profile: EmbeddingProfile?
        if let provider, case .available(let current) = await provider.availability() { profile = current }
        return try readiness(of: documentIDs, profile: profile)
    }

    // MARK: Internals

    private typealias Value = SQLiteDatabase.Value

    private func readiness(of documentIDs: Set<String>, profile: EmbeddingProfile?) throws -> [String: DocumentReadiness] {
        let rows = try database.query("""
            SELECT doc_id, checksum, lexical_ready, vector_ready, embedding_revision, embedding_dimension
            FROM documents WHERE doc_id IN (SELECT value FROM json_each(?))
            """, [.text(try Self.json(Array(documentIDs)))]) { row -> (String, DocumentReadiness) in
            let compatible = profile.map { row.optionalText(4) == $0.revision && row.int(5) == Int64($0.dimension) } ?? false
            return (row.text(0), DocumentReadiness(checksum: row.text(1), lexicalReady: row.int(2) == 1,
                                                   vectorReady: row.int(3) == 1 && compatible))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    private func lexicalCandidates(_ question: String, allowList: String, limit: Int) throws -> [SearchHit] {
        guard let match = FTSQuery.match(from: question) else { return [] }
        return try database.query("""
            SELECT p.id, p.doc_id, p.ordinal, p.page, p.section, p.text, p.page_label, d.checksum, p.ocr_confidence
            FROM passages_fts
            JOIN passages p ON p.id = passages_fts.rowid
            JOIN documents d ON d.doc_id = p.doc_id AND d.generation = p.generation
            WHERE passages_fts MATCH ?
              AND d.lexical_ready = 1
              AND EXISTS (SELECT 1 FROM json_each(?) j WHERE j.key = d.doc_id AND j.value = d.checksum)
            ORDER BY bm25(passages_fts)
            LIMIT ?
            """, [.text(match), .text(allowList), .int(Int64(limit))]) { Self.hit($0) }
    }

    private func vectorCandidates(_ query: [Float], profile: EmbeddingProfile, allowList: String, limit: Int) throws -> [SearchHit] {
        let table = Self.vectorTable(profile.dimension)
        guard try database.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) == 1
        else { return [] }
        // Eligible rows are live generations in scope whose vectors share the query's revision and dimension;
        // sqlite-vec applies the rowid filter while it selects the k nearest.
        return try database.query("""
            SELECT p.id, p.doc_id, p.ordinal, p.page, p.section, p.text, p.page_label, d.checksum, p.ocr_confidence
            FROM (
                SELECT rowid, distance FROM \(table)
                WHERE embedding MATCH ? AND k = ?
                  AND rowid IN (
                    SELECT p.id FROM passages p
                    JOIN documents d ON d.doc_id = p.doc_id AND d.generation = p.generation
                    WHERE EXISTS (SELECT 1 FROM json_each(?) j WHERE j.key = d.doc_id AND j.value = d.checksum)
                      AND d.vector_ready = 1 AND d.embedding_revision = ? AND d.embedding_dimension = ?)
            ) v
            JOIN passages p ON p.id = v.rowid
            JOIN documents d ON d.doc_id = p.doc_id AND d.generation = p.generation
            ORDER BY v.distance
            """, [.blob(Self.blob(query)), .int(Int64(limit)), .text(allowList), .text(profile.revision), .int(Int64(profile.dimension))]) {
            Self.hit($0)
        }
    }

    /// Reciprocal rank fusion; a passage found by both lists outranks one found by either alone.
    private static func fuse(lexical: [SearchHit], vector: [SearchHit], limit: Int) -> [SearchHit] {
        var merged: [Int64: SearchHit] = [:]
        for (list, isLexical) in [(lexical, true), (vector, false)] {
            for (rank, candidate) in list.enumerated() {
                var hit = merged[candidate.passageID] ?? candidate
                hit.score += 1.0 / Double(60 + rank + 1)
                if isLexical { hit.matchedLexically = true } else { hit.matchedByVector = true }
                merged[hit.passageID] = hit
            }
        }
        return merged.values
            .sorted { ($0.score, $1.passageID) > ($1.score, $0.passageID) }
            .prefix(limit).map { $0 }
    }

    private static func hit(_ row: SQLiteDatabase.Row) -> SearchHit {
        SearchHit(passageID: row.int(0), documentID: row.text(1), checksum: row.text(7), ordinal: Int(row.int(2)),
                  page: row.isNull(3) ? nil : Int(row.int(3)), pageLabel: row.optionalText(6),
                  section: row.optionalText(4), text: row.text(5),
                  ocrConfidence: row.isNull(8) ? nil : row.double(8),
                  score: 0, matchedLexically: false, matchedByVector: false)
    }

    private func nextGeneration() throws -> Int64 {
        try database.run("UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'generation'")
        return try database.scalarInt("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'generation'") ?? 1
    }

    /// Removes a document's rows, or with `keeping` every generation but that one (the staged one being published).
    private func removeRows(for documentID: String, keeping generation: Int64? = nil) throws {
        try removeVectors(for: documentID)
        let keep = generation.map(Value.int) ?? .null
        try database.run("""
            DELETE FROM passages_fts WHERE rowid IN
              (SELECT id FROM passages WHERE doc_id = ? AND (? IS NULL OR generation != ?))
            """, [.text(documentID), keep, keep])
        try database.run("DELETE FROM passages WHERE doc_id = ? AND (? IS NULL OR generation != ?)", [.text(documentID), keep, keep])
        try database.run("DELETE FROM documents WHERE doc_id = ?", [.text(documentID)])
    }

    /// Drops a document's unpublished generation, which no search can see.
    private func discardStaging(for documentID: String) throws {
        try database.run("""
            DELETE FROM passages_fts WHERE rowid IN
              (SELECT id FROM passages WHERE doc_id = ? AND generation IN (SELECT generation FROM staging WHERE doc_id = ?))
            """, [.text(documentID), .text(documentID)])
        try database.run("DELETE FROM passages WHERE doc_id = ? AND generation IN (SELECT generation FROM staging WHERE doc_id = ?)",
                         [.text(documentID), .text(documentID)])
        try database.run("DELETE FROM staging WHERE doc_id = ?", [.text(documentID)])
    }

    /// Nothing is writing when an index opens, so every unpublished generation was left by an interrupted run.
    private static func discardAbandonedStaging(_ database: SQLiteDatabase) throws -> Int {
        try database.transaction {
            let count = Int(try database.scalarInt("SELECT count(*) FROM staging") ?? 0)
            let orphans = """
                SELECT p.id FROM passages p LEFT JOIN documents d ON d.doc_id = p.doc_id AND d.generation = p.generation
                WHERE d.doc_id IS NULL
                """
            try database.run("DELETE FROM passages_fts WHERE rowid IN (\(orphans))")
            try database.run("DELETE FROM passages WHERE id IN (\(orphans))")
            try database.run("DELETE FROM staging")
            return count
        }
    }

    private func removeVectors(for documentID: String) throws {
        let recorded = try database.query("SELECT embedding_dimension FROM documents WHERE doc_id = ? AND vector_ready = 1",
                                          [.text(documentID)]) { Int($0.int(0)) }
        if let dimension = recorded.first, Self.isUsableDimension(dimension) {
            let table = Self.vectorTable(dimension)
            if try database.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) == 1 {
                for id in try database.query("SELECT id FROM passages WHERE doc_id = ?", [.text(documentID)], { $0.int(0) }) {
                    try database.run("DELETE FROM \(table) WHERE rowid = ?", [.int(id)])
                }
            }
        }
        try database.run("UPDATE documents SET vector_ready = 0, embedding_revision = NULL, embedding_dimension = NULL WHERE doc_id = ?",
                         [.text(documentID)])
    }

    // The dimension is an integer we validate, so it is the one value allowed into a table name.
    private static func isUsableDimension(_ dimension: Int) -> Bool { (1...8192).contains(dimension) }
    private static func isUsable(_ profile: EmbeddingProfile) -> Bool { isUsableDimension(profile.dimension) && !profile.revision.isEmpty }
    private static func vectorTable(_ dimension: Int) -> String { "passage_vectors_\(dimension)" }

    private static func blob(_ vector: [Float]) -> Data { vector.withUnsafeBytes { Data($0) } }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func prepareSchema(_ database: SQLiteDatabase) throws {
        let version = Int(try database.scalarInt("PRAGMA user_version") ?? 0)
        guard version <= schemaVersion else { throw DocumentSearchError.newerSchema(version) }
        guard version < schemaVersion else { return }
        // The index is disposable, so an older layout is rebuilt rather than migrated: the caller deletes the
        // file and indexes the documents again.
        guard version == 0 else { throw DocumentSearchError.outdatedSchema(version) }
        do {
            try database.transaction {
                try database.run("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try database.run("INSERT INTO meta (key, value) VALUES ('generation', '0')")
                try database.run("""
                    CREATE TABLE documents (
                        doc_id TEXT PRIMARY KEY,
                        generation INTEGER NOT NULL,
                        checksum TEXT NOT NULL,
                        extraction_version INTEGER NOT NULL,
                        chunking_version INTEGER NOT NULL,
                        language TEXT NOT NULL,
                        rig_id TEXT,
                        trip_id TEXT,
                        lexical_ready INTEGER NOT NULL DEFAULT 0,
                        vector_ready INTEGER NOT NULL DEFAULT 0,
                        embedding_revision TEXT,
                        embedding_dimension INTEGER,
                        outcome TEXT NOT NULL DEFAULT 'ready'
                    )
                    """)
                // A generation being built. Its passages carry its generation number, which no document row
                // references yet, so no query can see them until `commit` swaps the document row.
                try database.run("""
                    CREATE TABLE staging (
                        doc_id TEXT PRIMARY KEY,
                        generation INTEGER NOT NULL,
                        checksum TEXT NOT NULL,
                        extraction_version INTEGER NOT NULL,
                        chunking_version INTEGER NOT NULL,
                        language TEXT NOT NULL,
                        rig_id TEXT,
                        trip_id TEXT,
                        outcome TEXT NOT NULL,
                        passage_count INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try database.run("""
                    CREATE TABLE passages (
                        id INTEGER PRIMARY KEY,
                        doc_id TEXT NOT NULL,
                        generation INTEGER NOT NULL,
                        ordinal INTEGER NOT NULL,
                        page INTEGER,
                        page_label TEXT,
                        section TEXT,
                        text TEXT NOT NULL,
                        ocr_confidence REAL
                    )
                    """)
                try database.run("CREATE INDEX passages_by_document ON passages (doc_id, generation)")
                try database.run("CREATE VIRTUAL TABLE passages_fts USING fts5(text, tokenize = 'unicode61 remove_diacritics 2')")
                // PRAGMA can't be bound; the value is a constant.
                try database.run("PRAGMA user_version = \(schemaVersion)")
            }
        } catch DocumentSearchError.sqlite(_, let message) where message.contains("fts5") {
            throw DocumentSearchError.unsupportedBuild("FTS5: " + message)
        }
    }
}
