import Foundation

#if !canImport(NaturalLanguage)
/// Without a recognizer nothing can be confirmed as English, so nothing is admitted.
private struct EnglishOnlyUnavailableDetector: LanguageDetecting {
    func hypotheses(for text: String) -> [String: Double] { [:] }
}
#endif

/// Keeps the search index true to the library for one session. All indexing goes through here, one job at a
/// time: a pass compares the library with the index (metadata only), removes what is gone, then reads and
/// stages each missing or replaced document in short batches, yielding to searches between batches.
///
/// The index file is disposable. Nothing here logs document text, vectors, or questions.
public actor DocumentIndexCoordinator {
    public static let fileName = "documents.sqlite"

    public struct Configuration: Sendable {
        /// Passages written per staging transaction; the checkpoint between batches is where work can be
        /// cancelled or give way to a search.
        public var batchPassages = 50
        /// How often a library with documents still waiting for their bytes is looked at again.
        public var waitingPollInterval: Duration = .seconds(30)
        /// Foreground reconciles closer together than this are folded into the last one.
        public var minimumForegroundInterval: Duration = .seconds(10)
        /// Failed attempts per file before it stays a retryable failure until the next startup or foreground.
        public var maximumAttempts = 3
        public var interactivePollInterval: Duration = .milliseconds(25)
        public init() {}
    }

    public enum Trigger: Sendable {
        /// The app launched or the library opened. Failures get a fresh set of attempts.
        case startup
        /// A save, import, or sync changed documents.
        case change
        /// The app became active again.
        case foreground
    }

    private enum Phase { case closed, open, erased }

    private let directory: URL
    private let source: any DocumentIndexSource
    private let provider: (any EmbeddingProvider)?
    private let extractionVersion: Int
    private let languageDetector: any LanguageDetecting
    private let configuration: Configuration

    private var phase = Phase.closed
    private var session = 0
    private var index: DocumentSearchIndex?
    private var passTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pending = false
    private var needsRebuild = false
    private var isActive = true
    private var interactiveCount = 0
    private var lastForegroundPass: ContinuousClock.Instant?
    private var states: [String: DocumentIndexState] = [:]
    private var failures: [String: (checksum: String, attempts: Int)] = [:]
    private var observers: [UUID: AsyncStream<[String: DocumentIndexState]>.Continuation] = [:]
    /// How many times a damaged index was deleted and started again this session.
    public private(set) var rebuildCount = 0

    public init(directory: URL, source: any DocumentIndexSource, embedding provider: (any EmbeddingProvider)? = nil,
                extractionVersion: Int, languageDetector: (any LanguageDetecting)? = nil,
                configuration: Configuration = Configuration()) {
        self.directory = directory
        self.source = source
        self.provider = provider
        self.extractionVersion = extractionVersion
        self.languageDetector = languageDetector ?? Self.systemDetector
        self.configuration = configuration
    }

    private static var systemDetector: any LanguageDetecting {
        #if canImport(NaturalLanguage)
        NaturalLanguageDetector()
        #else
        EnglishOnlyUnavailableDetector()
        #endif
    }

    private var indexURL: URL { directory.appending(path: Self.fileName) }

    // MARK: Lifecycle

    /// Starts a session. An existing index is opened and checked; a missing one is created only when there is
    /// something to index, so an empty library leaves nothing on disk. A new session after an erase is explicit.
    public func open() {
        guard phase != .open else { return }
        phase = .open
        session += 1
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        index = openOrRebuild()
        if index == nil { phase = .closed }
    }

    /// Stops all work and closes the file, keeping it for the next launch.
    public func shutdown() async {
        guard phase == .open else { return }
        phase = .closed
        session += 1
        await stopWork()
        await index?.close()
        index = nil
    }

    /// Erase all data. Waits for the writer to finish, closes the file, and deletes the database, its journal
    /// sidecars, and everything else in the folder. Until `open()` starts a new session, nothing recreates them:
    /// reconciles, searches, and late saves do nothing. Returns false if something could not be removed.
    @discardableResult
    public func erase() async -> Bool {
        phase = .erased
        session += 1
        await stopWork()
        await index?.close()
        index = nil
        states = [:]
        publish()
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm", "-journal", ""] {
            try? fileManager.removeItem(atPath: indexURL.path + suffix)
        }
        try? fileManager.removeItem(at: directory)
        return !fileManager.fileExists(atPath: directory.path)
    }

    private func stopWork() async {
        pending = false
        pollTask?.cancel()
        pollTask = nil
        let task = passTask
        task?.cancel()
        await task?.value
        passTask = nil
    }

    /// Resolves once no pass is running or requested. For callers that must not proceed while indexing is in flight.
    public func waitUntilIdle() async {
        while let task = passTask { await task.value }
    }

    // MARK: Observing

    /// The state of every document the library holds, now.
    public func documentStates() -> [String: DocumentIndexState] { states }

    /// The current states, then a fresh snapshot whenever one changes.
    public func stateUpdates() -> AsyncStream<[String: DocumentIndexState]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: DocumentIndexState].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(states)
        continuation.onTermination = { [weak self] _ in Task { await self?.stopObserving(id) } }
        return stream
    }

    private func stopObserving(_ id: UUID) { observers[id] = nil }

    private func publish() {
        for continuation in observers.values { continuation.yield(states) }
    }

    private func set(_ id: String, _ state: DocumentIndexState) {
        guard states[id] != state else { return }
        states[id] = state
        publish()
    }

    // MARK: Reconciling

    /// Asks for the index to be brought in line with the library. Requests made while a pass runs are folded
    /// into one more pass, so there is never more than one job at a time or two jobs for the same document.
    public func reconcile(_ trigger: Trigger = .change) {
        guard phase != .erased else { return }
        if phase == .closed { open() }
        guard phase == .open else { return }
        switch trigger {
        case .startup:
            failures = [:]
        case .foreground:
            let now = ContinuousClock.now
            if let last = lastForegroundPass, now - last < configuration.minimumForegroundInterval { return }
            lastForegroundPass = now
            failures = [:]
        case .change:
            break
        }
        pending = true
        guard passTask == nil else { return }
        passTask = Task { [weak self] in await self?.runPasses() }
    }

    /// Tells the coordinator whether the app is in the foreground. Waiting documents are only polled while it is.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { reconcile(.foreground) } else { pollTask?.cancel(); pollTask = nil }
    }

    private func runPasses() async {
        let startedIn = session
        while pending, !Task.isCancelled, phase == .open, session == startedIn {
            pending = false
            do {
                if needsRebuild { rebuild() }
                try await pass(session: startedIn)
            } catch is CancellationError {
                break
            } catch let error as DocumentSearchError where error.isCorruption {
                needsRebuild = true
                pending = true
            } catch {
                // Best effort. The next change or foreground retries, and search uses what is ready.
            }
        }
        if session == startedIn { passTask = nil }
        if phase == .open, session == startedIn { armPoll() }
    }

    private func pass(session: Int) async throws {
        let documents = try await source.library()
        try ensureCurrent(session)
        if index == nil, documents.contains(where: { $0.availability == .ready }) {
            index = openOrRebuild()
        }
        let indexed = try await index?.indexedDocuments() ?? [:]
        try ensureCurrent(session)
        let exhausted = Set(documents.filter {
            guard let failure = failures[$0.id] else { return false }
            return failure.checksum == $0.checksum && failure.attempts >= configuration.maximumAttempts
        }.map(\.id))
        let plan = ReconciliationPlan.make(library: documents, indexed: indexed, extractionVersion: extractionVersion, exhausted: exhausted)

        // Deletion and opt-out take effect for search at once through the live allow-list; this only reclaims rows.
        for id in plan.remove { try await index?.remove(documentID: id) }
        failures = failures.filter { id, _ in documents.contains { $0.id == id } }
        states = plan.states
        publish()

        for document in plan.index {
            try await yieldToInteractiveWork(session)
            guard let index else { break }
            try await build(document, in: index, session: session)
        }
        try await catchUpVectors(for: documents.filter { $0.availability == .ready }.map(\.id), session: session)
    }

    private func build(_ document: LibraryDocument, in index: DocumentSearchIndex, session: Int) async throws {
        let id = document.id
        var token: StagingToken?
        do {
            set(id, .extracting)
            let result = try await source.read(document)
            try ensureCurrent(session)
            let published = { (outcome: IndexOutcome, language: String) in
                IndexedDocument(id: id, checksum: document.checksum, extractionVersion: self.extractionVersion,
                                chunkingVersion: PassageChunker.version, language: language, outcome: outcome)
            }
            switch result {
            case .waitingForDownload:
                set(id, .waitingForDownload)
            case .changed:
                set(id, .queued)
                pending = true
            case .noUsableText(let reason):
                try await index.publish(published(.noUsableText(reason), "und"), passages: [])
                set(id, .noUsableText(reason))
                failures[id] = nil
            case .text(let text):
                let chunked = PassageChunker.passages(from: text.pages)
                guard !chunked.isEmpty else {
                    try await index.publish(published(.noUsableText(.noText), text.language), passages: [])
                    set(id, .noUsableText(.noText))
                    failures[id] = nil
                    return
                }
                // Only confidently English passages are staged, so nothing else can reach search, FTS included.
                let admission = DocumentLanguagePolicy.admit(chunked, using: languageDetector)
                guard !admission.admitted.isEmpty else {
                    try await index.publish(published(.englishOnly, admission.language), passages: [])
                    set(id, .englishOnly)
                    failures[id] = nil
                    return
                }
                let passages = admission.admitted
                let outcome: IndexOutcome = admission.coverage == .partial ? .englishPartial
                    : (text.skippedPages > 0 ? .readPartially : .ready)
                let staging = try await index.beginStaging(published(outcome, admission.language))
                token = staging
                var done = 0
                set(id, .indexing(done: 0, of: passages.count))
                for batch in Self.batches(of: passages, size: configuration.batchPassages) {
                    try await yieldToInteractiveWork(session)
                    try await index.stage(staging, passages: batch)
                    done += batch.count
                    set(id, .indexing(done: done, of: passages.count))
                }
                try await yieldToInteractiveWork(session)
                try await index.commit(staging, embedding: provider)
                token = nil
                set(id, outcome == .englishPartial ? .englishPartial : (outcome == .readPartially ? .readPartially : .ready))
                failures[id] = nil
            }
        } catch {
            if let token { try? await index.abandon(token) }
            if error is CancellationError { throw error }
            if let error = error as? DocumentSearchError, error.isCorruption { throw error }
            let attempts = (failures[id]?.checksum == document.checksum ? failures[id]?.attempts ?? 0 : 0) + 1
            failures[id] = (document.checksum, attempts)
            set(id, .retryableFailure)
        }
    }

    /// Embeds documents whose vectors are missing or were built under another embedding revision. Until then
    /// they stay searchable lexically, because search ignores vectors that don't match the provider's profile.
    private func catchUpVectors(for ids: [String], session: Int) async throws {
        guard let index, let provider, case .available(let profile) = await provider.availability() else { return }
        let retired = try await index.retireIncompatibleVectors(keeping: profile)
        let readiness = try await index.readiness(of: Set(ids), embedding: provider)
        for id in ids where retired.contains(id) || readiness[id]?.vectorReady == false {
            try await yieldToInteractiveWork(session)
            _ = try? await index.indexVectors(documentID: id, embedding: provider)
        }
    }

    static func batches(of passages: [IndexedPassage], size: Int) -> [[IndexedPassage]] {
        var result: [[IndexedPassage]] = []
        var current: [IndexedPassage] = []
        for passage in passages {
            // Close a batch only at a page boundary, so a checkpoint never splits a page.
            if current.count >= size, passage.page != current.last?.page {
                result.append(current)
                current = []
            }
            current.append(passage)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Stops work from a session that has ended or been erased, which must never write again.
    private func ensureCurrent(_ session: Int) throws {
        try Task.checkCancellation()
        guard phase == .open, self.session == session else { throw CancellationError() }
    }

    /// A checkpoint: lets an in-flight search run first, so indexing never makes a question wait.
    private func yieldToInteractiveWork(_ session: Int) async throws {
        try ensureCurrent(session)
        await Task.yield()
        while interactiveCount > 0 {
            try await Task.sleep(for: configuration.interactivePollInterval)
            try ensureCurrent(session)
        }
    }

    private func armPoll() {
        pollTask?.cancel()
        pollTask = nil
        guard phase == .open, isActive, states.values.contains(.waitingForDownload) else { return }
        let interval = configuration.waitingPollInterval
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.reconcile(.change)
        }
    }

    // MARK: Files

    /// Opens the index in a protected, backup-excluded folder. A file that is damaged, from another layout,
    /// or unreadable is deleted and started fresh. Only index files are touched; the originals live in the library.
    private func openOrRebuild() -> DocumentSearchIndex? {
        if let opened = try? openFile() { return opened }
        removeIndexFiles()
        rebuildCount += 1
        return try? openFile()
    }

    private func openFile() throws -> DocumentSearchIndex {
        let fileManager = FileManager.default
        #if os(iOS)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let opened = try DocumentSearchIndex(url: indexURL, verifyIntegrity: true)
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: indexURL.path)
        #endif
        return opened
    }

    private func removeIndexFiles() {
        for suffix in ["-wal", "-shm", "-journal", ""] {
            try? FileManager.default.removeItem(atPath: indexURL.path + suffix)
        }
    }

    /// Deletes a damaged index and starts an empty one. Every document is then read again.
    private func rebuild() {
        needsRebuild = false
        index = nil
        removeIndexFiles()
        rebuildCount += 1
        index = try? openFile()
        states = [:]
        publish()
    }

    // MARK: Searching

    /// Passages for a question from the documents in `live` (document ID to the checksum the library holds
    /// now). Searches go ahead of indexing work. Nil when there is no index to search.
    public func search(_ question: String, live: [String: String], limit: Int = 8) async -> SearchResult? {
        guard phase == .open, let index else { return nil }
        interactiveCount += 1
        defer { interactiveCount -= 1 }
        do {
            return try await index.search(question, live: live, limit: limit, embedding: provider)
        } catch let error as DocumentSearchError where error.isCorruption {
            needsRebuild = true
            reconcile(.change)
            return nil
        } catch {
            return nil
        }
    }
}
