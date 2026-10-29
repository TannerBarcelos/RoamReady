import XCTest
@testable import DocumentSearch

/// A library the tests edit while the coordinator runs.
private actor FakeSource: DocumentIndexSource {
    struct Failure: Error {}

    private(set) var documents: [LibraryDocument] = []
    private var content: [String: DocumentReadResult] = [:]
    private var failing: Set<String> = []
    private(set) var reads: [String] = []
    private var isBlocking = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set(_ document: LibraryDocument, pages: [String]? = nil, result: DocumentReadResult? = nil) {
        documents.removeAll { $0.id == document.id }
        documents.append(document)
        if let pages {
            content[document.id] = .text(ExtractedDocument(pages: pages.enumerated().map {
                ExtractedPage(ordinal: $0.offset + 1, text: $0.element)
            }, language: "en", isEnglish: true))
        }
        if let result { content[document.id] = result }
    }

    func remove(_ id: String) { documents.removeAll { $0.id == id } }
    func fail(_ id: String, _ fails: Bool) { if fails { failing.insert(id) } else { failing.remove(id) } }

    /// Reads wait here until `release()`.
    func block() { isBlocking = true }
    func release() {
        isBlocking = false
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func library() async throws -> [LibraryDocument] { documents }

    func read(_ document: LibraryDocument) async throws -> DocumentReadResult {
        reads.append(document.id)
        if isBlocking { await withCheckedContinuation { waiters.append($0) } }
        if failing.contains(document.id) { throw Failure() }
        return content[document.id] ?? .noUsableText(.noText)
    }
}

/// Embeddings whose revision the test can change, and whose query embedding can be held.
private final class SwitchableProvider: EmbeddingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = "rev-1"
    private var holdsQueries = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func setRevision(_ value: String) { lock.withLock { revision = value } }
    func holdQueries() { lock.withLock { holdsQueries = true } }
    func releaseQueries() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holdsQueries = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    private var current: DeterministicEmbeddingProvider { DeterministicEmbeddingProvider(revision: lock.withLock { revision }) }
    func availability() async -> EmbeddingAvailability { await current.availability() }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        // Only a single text is a question; passages are embedded in batches.
        if texts.count == 1, lock.withLock({ holdsQueries }) {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if holdsQueries { held.append(continuation); return false }
                    return true
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try await current.embed(texts)
    }
}

final class DocumentIndexCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var source: FakeSource!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID().uuidString)")
        source = FakeSource()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func coordinator(provider: (any EmbeddingProvider)? = nil, configure: (inout DocumentIndexCoordinator.Configuration) -> Void = { _ in }) -> DocumentIndexCoordinator {
        var configuration = DocumentIndexCoordinator.Configuration()
        configuration.waitingPollInterval = .milliseconds(40)
        configuration.interactivePollInterval = .milliseconds(5)
        configure(&configuration)
        return DocumentIndexCoordinator(directory: directory, source: source, embedding: provider, extractionVersion: 1,
                                        languageDetector: AlwaysEnglish(), configuration: configuration)
    }

    private func doc(_ id: String, _ checksum: String = "c1", _ availability: LibraryDocument.Availability = .ready) -> LibraryDocument {
        LibraryDocument(id: id, checksum: checksum, availability: availability)
    }

    private func doc(_ id: String, _ checksum: String = "c1", availability: LibraryDocument.Availability) -> LibraryDocument {
        LibraryDocument(id: id, checksum: checksum, availability: availability)
    }

    private func eventually(_ message: String = "condition", file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(message)", file: file, line: line)
    }

    private func texts(_ result: SearchResult?) -> [String] { result?.hits.map(\.text) ?? [] }

    private var indexFile: URL { directory.appendingPathComponent(DocumentIndexCoordinator.fileName) }

    // MARK: Updates

    func testNewDocumentsAreIndexedAutomaticallyAndReportTheirState() async throws {
        await source.set(doc("a"), pages: ["Error code E4 means the igniter failed to light."])
        await source.set(doc("scan"), result: .noUsableText(.noText))
        await source.set(doc("photo", availability: .unsupported))
        let coordinator = coordinator()
        await coordinator.open()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()

        let states = await coordinator.documentStates()
        XCTAssertEqual(states, ["a": .ready, "scan": .noUsableText(.noText), "photo": .unsupported])
        let result = await coordinator.search("E4", live: ["a": "c1"])
        XCTAssertEqual(result?.hits.first?.page, 1)
    }

    func testReplacingADocumentNeverServesTheOldChecksumWhileTheNewOneIndexes() async throws {
        await source.set(doc("a", "v1"), pages: ["The igniter is part 4471 in the first edition."])
        let coordinator = coordinator()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        let first = await coordinator.search("igniter", live: ["a": "v1"])
        XCTAssertEqual(first?.hits.count, 1)

        await source.block()
        await source.set(doc("a", "v2"), pages: ["The igniter is part 5502 in the second edition."])
        await coordinator.reconcile(.change)
        await eventually("the new version to be read") { await source.reads.count == 2 }

        let whileIndexing = await coordinator.search("igniter", live: ["a": "v2"])
        XCTAssertEqual(texts(whileIndexing), [], "the first edition's rows are not evidence for the second file")

        await source.release()
        await coordinator.waitUntilIdle()
        let after = await coordinator.search("igniter", live: ["a": "v2"])
        XCTAssertEqual(texts(after), ["The igniter is part 5502 in the second edition."])
        let old = await coordinator.search("igniter", live: ["a": "v1"])
        XCTAssertEqual(texts(old), [])
    }

    func testAnInterruptedIndexRestartsCleanlyAndNeverServesTheOldChecksum() async throws {
        // A previous run died after staging half of a replacement.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftover = try DocumentSearchIndex(url: indexFile)
        let current = IndexedDocument(id: "a", checksum: "v1", extractionVersion: 1, chunkingVersion: PassageChunker.version, language: "en")
        try await leftover.publish(current, passages: [IndexedPassage(text: "Old edition igniter text.", page: 1)])
        var replacement = current
        replacement.checksum = "v2"
        let token = try await leftover.beginStaging(replacement)
        try await leftover.stage(token, passages: [IndexedPassage(text: "Half of the new edition igniter text.", page: 1)])
        await leftover.close()

        await source.set(doc("a", "v2"), pages: ["New edition igniter text.", "Second page about the igniter."])
        let coordinator = coordinator()
        await coordinator.open()
        let beforeIndexing = await coordinator.search("igniter", live: ["a": "v2"])
        XCTAssertEqual(texts(beforeIndexing), [])

        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        let after = await coordinator.search("igniter", live: ["a": "v2"])
        XCTAssertEqual(Set(texts(after)), ["New edition igniter text.", "Second page about the igniter."])
    }

    func testShuttingDownMidIndexLeavesOnlyTheOldGenerationAndTheNextRunFinishes() async throws {
        await source.set(doc("a", "v1"), pages: ["The old edition igniter text."])
        let first = coordinator()
        await first.reconcile(.startup)
        await first.waitUntilIdle()

        await source.block()
        await source.set(doc("a", "v2"), pages: ["The new edition igniter text."])
        await first.reconcile(.change)
        await eventually("the replacement to start reading") { await source.reads.count == 2 }
        let shutdown = Task { await first.shutdown() }
        await source.release()
        await shutdown.value

        let second = coordinator()
        await second.reconcile(.startup)
        await second.waitUntilIdle()
        let result = await second.search("igniter", live: ["a": "v2"])
        XCTAssertEqual(texts(result), ["The new edition igniter text."])
    }

    func testLargeDocumentsAreStagedInPageAlignedBatchesAndPublishedOnce() async throws {
        var passages: [IndexedPassage] = []
        for page in 1...4 { for number in 1...3 { passages.append(IndexedPassage(text: "Passage \(number) on page \(page).", page: page)) } }
        let batches = DocumentIndexCoordinator.batches(of: passages, size: 4)
        XCTAssertEqual(batches.map(\.count), [6, 6], "a batch closes only where the page changes")
        XCTAssertEqual(batches.flatMap { $0 }, passages)

        let pages = (1...6).map { "Page \($0) explains the furnace routine in plain words." }
        await source.set(doc("big"), pages: pages)
        let coordinator = coordinator { $0.batchPassages = 2 }
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        let state = await coordinator.documentStates()["big"]
        XCTAssertEqual(state, .ready)
        let result = await coordinator.search("furnace", live: ["big": "c1"])
        XCTAssertEqual(result?.hits.count, 6)
    }

    func testStateUpdatesStartWithTheCurrentStatesAndFollowChanges() async throws {
        await source.set(doc("a"), pages: ["Plain text about the awning and its arms."])
        let coordinator = coordinator()
        var updates = await coordinator.stateUpdates().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial, [:])
        await coordinator.reconcile(.startup)
        var latest: [String: DocumentIndexState]?
        while let snapshot = await updates.next() {
            latest = snapshot
            if snapshot["a"] == .ready { break }
        }
        XCTAssertEqual(latest?["a"], .ready)
    }

    // MARK: Deletion and opt-out

    func testDeletedAndOptedOutDocumentsLeaveAnswersAtOnceAndTheirRowsAreReclaimed() async throws {
        await source.set(doc("keep"), pages: ["Shared warranty wording for the trailer."])
        await source.set(doc("gone"), pages: ["Shared warranty wording for the trailer."])
        let coordinator = coordinator()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()

        // The caller builds `live` from the library, which no longer lists "gone", before any pass has run.
        let immediately = await coordinator.search("warranty", live: ["keep": "c1"])
        XCTAssertEqual(immediately?.hits.map(\.documentID), ["keep"])

        await source.remove("gone")
        await coordinator.reconcile(.change)
        await coordinator.waitUntilIdle()
        await coordinator.shutdown()
        let reopened = try DocumentSearchIndex(url: indexFile)
        let rows = try await reopened.indexedDocuments()
        XCTAssertEqual(Set(rows.keys), ["keep"])
    }

    // MARK: iCloud

    func testMetadataBeforeBytesWaitsThenIndexesWhenTheBytesArrive() async throws {
        await source.set(doc("a", availability: .waitingForDownload), pages: ["Check-in is at 3 p.m. at the front office."])
        let coordinator = coordinator()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        let waiting = await coordinator.documentStates()
        let reads = await source.reads
        XCTAssertEqual(waiting["a"], .waitingForDownload)
        XCTAssertEqual(reads, [], "a waiting document is not read, and it isn't a failure")

        // The bytes arrive; nothing tells the coordinator, which looks again on its own.
        await source.set(doc("a", availability: .ready), pages: ["Check-in is at 3 p.m. at the front office."])
        await eventually("the arrived document to be indexed") { await coordinator.documentStates()["a"] == .ready }
        let result = await coordinator.search("check-in", live: ["a": "c1"])
        XCTAssertEqual(result?.hits.count, 1)
    }

    func testAReplacementWaitingForItsBytesDropsTheSupersededGeneration() async throws {
        await source.set(doc("a", "v1"), pages: ["The old edition igniter text."])
        let coordinator = coordinator()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        await source.set(doc("a", "v2", .waitingForDownload))
        await coordinator.reconcile(.change)
        await coordinator.waitUntilIdle()
        await coordinator.shutdown()
        let rows = try await DocumentSearchIndex(url: indexFile).indexedDocuments()
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: Embeddings

    func testAnEmbeddingRevisionChangeKeepsLexicalSearchAndThenReembeds() async throws {
        let provider = SwitchableProvider()
        await source.set(doc("a"), pages: ["Drain the fresh water tank before winter storage."])
        let coordinator = coordinator(provider: provider)
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        let before = await coordinator.search("winter storage", live: ["a": "c1"])
        XCTAssertEqual(before?.usedVectors, true)

        provider.setRevision("rev-2")
        let whileStale = await coordinator.search("winter storage", live: ["a": "c1"])
        XCTAssertEqual(whileStale?.usedVectors, false)
        XCTAssertEqual(whileStale?.hits.count, 1, "lexical results continue while vectors are out of date")

        await coordinator.reconcile(.foreground)
        await coordinator.waitUntilIdle()
        let rebuilt = await coordinator.search("winter storage", live: ["a": "c1"])
        XCTAssertEqual(rebuilt?.usedVectors, true)
    }

    // MARK: Failures and bounds

    func testFailuresAreRetryableAndBoundedUntilTheNextForeground() async throws {
        await source.set(doc("a"), pages: ["Plain text about the awning and its arms."])
        await source.fail("a", true)
        let coordinator = coordinator { $0.maximumAttempts = 2; $0.minimumForegroundInterval = .zero }
        for _ in 0..<5 {
            await coordinator.reconcile(.change)
            await coordinator.waitUntilIdle()
        }
        let failed = await coordinator.documentStates()
        let attempts = await source.reads.count
        XCTAssertEqual(failed["a"], .retryableFailure)
        XCTAssertEqual(attempts, 2, "saves don't hammer a file that keeps failing")

        await source.fail("a", false)
        await coordinator.reconcile(.foreground)
        await coordinator.waitUntilIdle()
        let recovered = await coordinator.documentStates()
        XCTAssertEqual(recovered["a"], .ready)
    }

    func testRequestsDuringAPassFoldIntoOneJobPerDocument() async throws {
        await source.set(doc("a"), pages: ["Plain text about the awning and its arms."])
        await source.set(doc("b"), pages: ["Plain text about the stabilizer jacks."])
        await source.block()
        let coordinator = coordinator()
        for _ in 0..<10 { await coordinator.reconcile(.change) }
        await eventually("the first read") { await source.reads.count == 1 }
        for _ in 0..<10 { await coordinator.reconcile(.change) }
        await source.release()
        await coordinator.waitUntilIdle()
        let reads = await source.reads.sorted()
        XCTAssertEqual(reads, ["a", "b"], "one at a time, and never twice")
    }

    func testIndexingWaitsForAnInFlightQuestion() async throws {
        let provider = SwitchableProvider()
        await source.set(doc("a"), pages: ["Plain text about the awning and its arms."])
        let coordinator = coordinator(provider: provider)
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()

        provider.holdQueries()
        let question = Task { await coordinator.search("awning", live: ["a": "c1"]) }
        try await Task.sleep(for: .milliseconds(50))
        await source.set(doc("b"), pages: ["Plain text about the stabilizer jacks."])
        await coordinator.reconcile(.change)
        try await Task.sleep(for: .milliseconds(150))
        let duringQuestion = await source.reads
        XCTAssertEqual(duringQuestion, ["a"], "the new document isn't read while a question is being answered")

        provider.releaseQueries()
        _ = await question.value
        await coordinator.waitUntilIdle()
        let reads = await source.reads
        XCTAssertEqual(reads, ["a", "b"])
    }

    func testAnEmptyLibraryLeavesNothingOnDisk() async throws {
        let coordinator = coordinator()
        await coordinator.open()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        _ = await coordinator.search("anything", live: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Corruption

    func testACorruptIndexIsDetectedAndRebuiltFromTheOriginalsWithoutTouchingThem() async throws {
        await source.set(doc("a"), pages: ["Error code E4 means the igniter failed to light."])
        let first = coordinator()
        await first.reconcile(.startup)
        await first.waitUntilIdle()
        await first.shutdown()
        try Data("garbage, not a database".utf8).write(to: indexFile)

        let second = coordinator()
        await second.open()
        let rebuilds = await second.rebuildCount
        XCTAssertEqual(rebuilds, 1)
        await second.reconcile(.startup)
        await second.waitUntilIdle()
        let result = await second.search("E4", live: ["a": "c1"])
        XCTAssertEqual(result?.hits.count, 1)
        let library = await source.documents
        XCTAssertEqual(library, [doc("a")], "the library is only read from")
    }

    // MARK: Erase

    func testEraseWaitsForTheWriterThenRemovesEverythingAndNothingRecreatesIt() async throws {
        await source.set(doc("a"), pages: ["Plain text about the awning and its arms."])
        let coordinator = coordinator()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        // What a crash can leave beside the database.
        for suffix in ["-wal", "-shm", "-journal"] { try Data("x".utf8).write(to: URL(filePath: indexFile.path + suffix)) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Staging"), withIntermediateDirectories: true)
        try Data("page".utf8).write(to: directory.appendingPathComponent("Staging/page.tmp"))

        // A replacement is being read when the owner erases.
        await source.block()
        await source.set(doc("a", "v2"), pages: ["Replacement text about the awning."])
        await coordinator.reconcile(.change)
        await eventually("the replacement to start reading") { await source.reads.count == 2 }
        let erasing = Task { await coordinator.erase() }
        await source.release()
        let removed = await erasing.value
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // Late saves, foregrounds, polls, and questions arrive after the erase.
        await coordinator.reconcile(.change)
        await coordinator.reconcile(.foreground)
        await coordinator.setActive(true)
        let answer = await coordinator.search("awning", live: ["a": "v2"])
        try await Task.sleep(for: .milliseconds(150))
        await coordinator.waitUntilIdle()
        XCTAssertNil(answer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing recreated the folder")
        let states = await coordinator.documentStates()
        XCTAssertTrue(states.isEmpty)
    }

    func testANewSessionAfterEraseStartsEmptyAndIndexesAgain() async throws {
        await source.set(doc("a"), pages: ["Plain text about the awning and its arms."])
        let coordinator = coordinator()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        await coordinator.erase()

        await coordinator.open()
        await coordinator.reconcile(.startup)
        await coordinator.waitUntilIdle()
        let result = await coordinator.search("awning", live: ["a": "c1"])
        XCTAssertEqual(result?.hits.count, 1)
    }
}

final class ReconciliationPlanTests: XCTestCase {
    private func record(_ checksum: String, outcome: IndexOutcome = .ready, version: Int = 1) -> IndexedDocumentRecord {
        IndexedDocumentRecord(checksum: checksum, extractionVersion: version, chunkingVersion: PassageChunker.version, outcome: outcome)
    }

    func testThePlanDecidesFromMetadataAlone() {
        let library = [
            LibraryDocument(id: "current", checksum: "a", availability: .ready),
            LibraryDocument(id: "replaced", checksum: "b2", availability: .ready),
            LibraryDocument(id: "new", checksum: "c", availability: .ready),
            LibraryDocument(id: "waiting", checksum: "d", availability: .waitingForDownload),
            LibraryDocument(id: "waitingReplacement", checksum: "e2", availability: .waitingForDownload),
            LibraryDocument(id: "image", checksum: "f", availability: .unsupported),
            LibraryDocument(id: "scan", checksum: "g", availability: .ready),
            LibraryDocument(id: "stuck", checksum: "h", availability: .ready)
        ]
        let indexed = [
            "current": record("a"), "replaced": record("b1"), "waitingReplacement": record("e1"), "image": record("f"),
            "scan": record("g", outcome: .noUsableText(.noText)), "deleted": record("z")
        ]
        let plan = ReconciliationPlan.make(library: library, indexed: indexed, extractionVersion: 1, exhausted: ["stuck"])

        XCTAssertEqual(plan.index.map(\.id), ["replaced", "new"])
        XCTAssertEqual(Set(plan.remove), ["deleted", "waitingReplacement", "image"])
        XCTAssertEqual(plan.states["current"], .ready)
        XCTAssertEqual(plan.states["replaced"], .queued)
        XCTAssertEqual(plan.states["waiting"], .waitingForDownload)
        XCTAssertEqual(plan.states["image"], .unsupported)
        XCTAssertEqual(plan.states["scan"], .noUsableText(.noText))
        XCTAssertEqual(plan.states["stuck"], .retryableFailure)
    }

    func testANewExtractionVersionQueuesEveryDocumentAgain() {
        let plan = ReconciliationPlan.make(library: [LibraryDocument(id: "a", checksum: "a", availability: .ready)],
                                           indexed: ["a": record("a", version: 1)], extractionVersion: 2)
        XCTAssertEqual(plan.index.map(\.id), ["a"])
    }
}

/// These tests are about the index lifecycle, so their short synthetic passages count as English.
private struct AlwaysEnglish: LanguageDetecting {
    func hypotheses(for text: String) -> [String: Double] { ["en": 1] }
}
