import Foundation
import Observation
import SwiftData
import CampCore
import CampPersistence
import DocumentSearch
import DocumentVault

/// The app's side of the document search index for a library session: where the index lives, feeding it the
/// library, answering scoped searches, and erasing it. `LibraryController` creates and drives it. The rules
/// for keeping the index true to the library (staged generations, reconciliation, erase) live in
/// `DocumentIndexCoordinator`, in the `DocumentSearch` package.
///
/// The index is disposable. Nothing here logs document text, vectors, or questions.
@MainActor @Observable
final class DocumentAssistantIndex {
    /// This session's view of each document's indexing, for status UI later.
    private(set) var statuses: [UUID: DocumentIndexState] = [:]
    private(set) var isOpen = false

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var coordinator: DocumentIndexCoordinator?
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private let provider = AppleEmbeddingProvider()

    init(directory: URL) { self.directory = directory }

    // MARK: Lifecycle

    /// Starts a session over this library. The index opens in a protected, backup-excluded folder and is
    /// reconciled with the documents; a file that is damaged is rebuilt from them.
    func open(context: ModelContext) {
        guard coordinator == nil else { return }
        let coordinator = DocumentIndexCoordinator(directory: directory, source: LibraryDocumentSource(context: context),
                                                   embedding: provider, extractionVersion: DocumentTextExtractor.version)
        self.coordinator = coordinator
        isOpen = true
        observing = Task { [weak self] in
            for await snapshot in await coordinator.stateUpdates() {
                guard let self else { return }
                self.statuses = Dictionary(uniqueKeysWithValues: snapshot.compactMap { id, state in UUID(uuidString: id).map { ($0, state) } })
            }
        }
        Task {
            await coordinator.open()
            await coordinator.reconcile(.startup)
        }
    }

    /// Waits for the writer to stop, then deletes the index and everything beside it. Nothing recreates the
    /// index until `open(context:)` starts a new library session.
    func erase() async {
        observing?.cancel()
        observing = nil
        isOpen = false
        statuses = [:]
        let coordinator = coordinator
        self.coordinator = nil
        await coordinator?.erase()
    }

    // MARK: Keeping the index current

    /// Asks for the index to be brought in line with the library after a save, import, or sync. Requests made
    /// while a pass runs are folded into one more pass.
    func scheduleSync() {
        guard let coordinator else { return }
        Task { await coordinator.reconcile(.change) }
    }

    /// Indexing continues while the app is active whatever sheet is open, and looks again for documents
    /// waiting on iCloud. Becoming active also reconciles, which is how a new embedding model is noticed.
    func setActive(_ active: Bool) {
        guard let coordinator else { return }
        Task { await coordinator.setActive(active) }
    }

    // MARK: Asking

    /// Evidence for a question in the scope it was asked in, or nil when no document is in scope and indexed
    /// yet (the chat then answers as it always has). Uses whatever is ready now and never waits for indexing.
    /// The target is the request's own snapshot; nothing here reads the screen's current rig or trip.
    func evidence(for question: String, target: AssistantScopeTarget, in context: ModelContext) async -> DocumentEvidence? {
        guard let coordinator else { return nil }
        let scope = context.documentScope(for: target)
        // Only documents indexed from the file the library holds now may be searched, so a replaced file's
        // old passages and a deleted or reassigned document's stale rows are never candidates.
        let live = Dictionary(uniqueKeysWithValues: scope.live.compactMap { id, document in document.checksum.map { (id.uuidString, $0) } })
        guard !live.isEmpty,
              let result = await coordinator.search(question, live: live, limit: 8),
              !Task.isCancelled else { return nil }
        #if DEBUG
        // Counts only, never text, and only for the fixture.
        if ProcessInfo.processInfo.arguments.contains("-document-assistant-fixture") {
            NSLog("DOCUMENT-SEARCH: usedVectors=%d hits=%d", result.usedVectors ? 1 : 0, result.hits.count)
        }
        #endif
        let candidates = result.hits.compactMap { hit -> DocumentEvidenceCandidate? in
            UUID(uuidString: hit.documentID).map {
                DocumentEvidenceCandidate(documentID: $0, indexedChecksum: hit.checksum, page: hit.page,
                                          pageLabel: hit.pageLabel, section: hit.section, text: hit.text,
                                          ocrConfidence: hit.ocrConfidence)
            }
        }
        // Check the library again, now, so a document deleted, reassigned, or replaced during the search is dropped.
        let live = context.documentScope(for: target).live
        let evidence = DocumentEvidence.make(question: question, candidates: candidates, live: live)
        guard target.isTrip, let followUp = await bookingFollowUp(for: question, allowList: allowList, live: live, in: index) else {
            return evidence
        }
        return evidence.merging(followUp: followUp)
    }

    /// A booking question can match one confirmation and miss another that says something different. One more
    /// search, still inside the trip's allow-list and limited to its Reservation documents, fetches the competing
    /// passage so the camper sees both values. Nothing is written; failures just leave the first result.
    private func bookingFollowUp(for question: String, allowList: Set<String>, live: [UUID: LiveDocument],
                                 in index: DocumentSearchIndex) async -> DocumentEvidence? {
        guard let query = BookingFactQuestion.followUpQuery(for: question) else { return nil }
        let reservations = allowList.filter { id in UUID(uuidString: id).flatMap { live[$0] }?.category == DocumentCategory.reservation.title }
        guard !reservations.isEmpty,
              let result = try? await index.search(query, documentIDs: reservations, limit: 8, embedding: provider),
              !Task.isCancelled else { return nil }
        let candidates = result.hits.compactMap { hit -> DocumentEvidenceCandidate? in
            UUID(uuidString: hit.documentID).map {
                DocumentEvidenceCandidate(documentID: $0, indexedChecksum: hit.checksum, page: hit.page,
                                          pageLabel: hit.pageLabel, section: hit.section, text: hit.text)
            }
        }
        // Validated against the library as it is now, like the first pass.
        return DocumentEvidence.make(question: query, candidates: candidates, live: live)
    }
}

/// The library as the index coordinator reads it. Model access stays on the main actor; reading and
/// extracting a document's bytes happens elsewhere, from a `Sendable` snapshot.
@MainActor
final class LibraryDocumentSource: DocumentIndexSource {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func library() async throws -> [LibraryDocument] {
        try context.indexableDocuments().map { document in
            let availability: LibraryDocument.Availability = switch document.availability {
            case .ready: .ready
            case .waitingForDownload: .waitingForDownload
            case .unsupported: .unsupported
            }
            return LibraryDocument(id: document.documentID.uuidString, checksum: document.checksum, availability: availability)
        }
    }

    func read(_ document: LibraryDocument) async throws -> DocumentReadResult {
        guard let id = UUID(uuidString: document.id) else { return .changed }
        // Capture on this actor; read, extract, and chunk elsewhere.
        guard let job = try context.indexJob(documentID: id, checksum: document.checksum) else {
            if let stored = context.document(withID: id), stored.checksum == document.checksum, stored.availability == .awaitingDownload {
                return .waitingForDownload
            }
            return .changed
        }
        return try await Task.detached(priority: .utility) { try Self.prepare(job.content) }.value
    }

    private nonisolated static func prepare(_ content: DocumentContentSnapshot) throws -> DocumentReadResult {
        // A failure to read the stored bytes is retryable; a file that holds no text is not.
        let bytes = try content.verifiedBytes()
        let extraction = DocumentTextExtractor.extract(from: bytes)
        switch extraction.outcome {
        case .noUsableText(let reason): return .noUsableText(reason)
        // The recognizer failed (for example while its model was preparing); this says nothing about the file.
        case .retryLater: throw DocumentError.contentNotDownloaded
        case .ready(_, let skipped):
            return .text(ExtractedDocument(pages: extraction.pages, language: extraction.language,
                                           isEnglish: extraction.isEnglish, skippedPages: skipped))
        }
    }
}
