import Foundation
import Observation
import SwiftData
import CampCore
import CampPersistence
import DocumentSearch
import DocumentVault

/// Owns the document search index for a library session: where it lives, keeping it current with the
/// documents, answering scoped searches, and erasing it. `LibraryController` creates and drives it.
///
/// The index is disposable. Nothing here logs document text, vectors, or questions.
@MainActor @Observable
final class DocumentAssistantIndex {
    enum Status: Equatable {
        case indexing
        case ready
        /// Some pages were left unread because the recognition caps were reached.
        case readPartially
        /// Final for this file: it is recorded and not read again until it changes.
        case noUsableText(NoUsableTextReason)
        case englishOnly
    }

    /// This session's view of each document's indexing, for status UI later.
    private(set) var statuses: [UUID: Status] = [:]
    private(set) var isOpen = false

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var index: DocumentSearchIndex?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private let provider = AppleEmbeddingProvider()

    init(directory: URL) { self.directory = directory }

    // MARK: Lifecycle

    /// Opens (or rebuilds) the index in a protected, backup-excluded folder. A file that can't be opened or is
    /// from another layout is deleted and started fresh; the documents are the source of truth.
    func open() {
        guard index == nil else { return }
        do {
            index = try openIndex()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            index = try? openIndex()
        }
        isOpen = index != nil
    }

    private func openIndex() throws -> DocumentSearchIndex {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let file = directory.appending(path: "documents.sqlite")
        let index = try DocumentSearchIndex(url: file)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        return index
    }

    /// Stops all work, closes the file, and deletes everything. Nothing recreates the index until `open()`
    /// is called again for a new library session.
    func erase() async {
        syncRequested = false
        syncTask?.cancel()
        await syncTask?.value
        syncTask = nil
        await index?.close()
        index = nil
        isOpen = false
        statuses = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Keeping the index current

    /// Brings the index in line with the library: new and changed documents are read and indexed, deleted or
    /// no-longer-eligible ones are removed. Requests made while a pass runs are folded into one more pass.
    func scheduleSync(in context: ModelContext) {
        guard index != nil else { return }
        syncRequested = true
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while let self, self.syncRequested, !Task.isCancelled {
                self.syncRequested = false
                await self.syncOnce(in: context)
            }
            self?.syncTask = nil
        }
    }

    private func syncOnce(in context: ModelContext) async {
        guard let index else { return }
        do {
            let wanted = try context.indexableDocuments()
            let known = try await index.indexedDocuments()
            let wantedIDs = Set(wanted.map { $0.documentID.uuidString })
            var reused = 0, indexed = 0
            #if DEBUG
            defer { if ProcessInfo.processInfo.arguments.contains("-document-assistant-fixture") { NSLog("DOCUMENT-INDEX: indexed=%d reused=%d", indexed, reused) } }
            #endif
            for id in known.keys where !wantedIDs.contains(id) {
                try await index.remove(documentID: id)
                if let uuid = UUID(uuidString: id) { statuses[uuid] = nil }
            }
            for document in wanted {
                try Task.checkCancellation()
                if known[document.documentID.uuidString]?.isCurrent(checksum: document.checksum, extractionVersion: DocumentTextExtractor.version) == true {
                    statuses[document.documentID] = statuses[document.documentID] ?? .ready
                    reused += 1
                    continue
                }
                statuses[document.documentID] = .indexing
                // Capture on this actor; read, extract, and chunk elsewhere.
                guard let job = try context.indexJob(documentID: document.documentID, checksum: document.checksum) else {
                    statuses[document.documentID] = nil
                    continue
                }
                let prepared = await Task.detached(priority: .utility) { Self.prepare(job.content) }.value
                try Task.checkCancellation()
                guard self.index === index else { return }
                guard prepared.isFinal else { statuses[job.documentID] = nil; continue }
                let published = IndexedDocument(id: job.documentID.uuidString, checksum: job.checksum,
                                             extractionVersion: DocumentTextExtractor.version,
                                             chunkingVersion: PassageChunker.version, language: prepared.language)
                // A document with nothing usable is still recorded, so it isn't read again until it changes.
                try await index.publish(published, passages: prepared.passages, embedding: provider)
                statuses[job.documentID] = prepared.status
                indexed += 1
            }
            try await catchUpVectors(for: wantedIDs, in: index)
        } catch {
            // Indexing is best effort and retried on the next change; chat falls back to what is ready.
        }
    }

    /// Embeds documents whose vectors are missing or were built by another embedding revision.
    private func catchUpVectors(for ids: Set<String>, in index: DocumentSearchIndex) async throws {
        guard case .available(let profile) = await provider.availability() else { return }
        let stale = try await index.retireIncompatibleVectors(keeping: profile)
        let readiness = try await index.readiness(of: ids, embedding: provider)
        for id in ids where stale.contains(id) || readiness[id]?.vectorReady == false {
            try Task.checkCancellation()
            _ = try? await index.indexVectors(documentID: id, embedding: provider)
        }
    }

    private struct Prepared: Sendable {
        var passages: [IndexedPassage]
        var language: String
        var status: Status
        /// False when the reader failed for a reason that says nothing about the file: nothing is recorded, so
        /// the next sync tries again.
        var isFinal = true
    }

    private nonisolated static func prepare(_ content: DocumentContentSnapshot) -> Prepared {
        guard let bytes = try? content.verifiedBytes() else {
            return Prepared(passages: [], language: "und", status: .noUsableText(.unreadable))
        }
        let extraction = DocumentTextExtractor.extract(from: bytes)
        if extraction.outcome == .retryLater {
            return Prepared(passages: [], language: extraction.language, status: .indexing, isFinal: false)
        }
        if case .noUsableText(let reason) = extraction.outcome {
            return Prepared(passages: [], language: extraction.language, status: .noUsableText(reason))
        }
        guard extraction.isEnglish else { return Prepared(passages: [], language: extraction.language, status: .englishOnly) }
        let passages = PassageChunker.passages(from: extraction.pages)
        guard !passages.isEmpty else { return Prepared(passages: [], language: extraction.language, status: .noUsableText(.noText)) }
        var status = Status.ready
        if case .ready(_, let skipped) = extraction.outcome, skipped > 0 { status = .readPartially }
        return Prepared(passages: passages, language: extraction.language, status: status)
    }

    // MARK: Asking

    /// Evidence for a question in the scope it was asked in, or nil when no document is in scope and indexed
    /// yet (the chat then answers as it always has). Uses whatever is ready now and never waits for indexing.
    /// The target is the request's own snapshot; nothing here reads the screen's current rig or trip.
    func evidence(for question: String, target: AssistantScopeTarget, in context: ModelContext) async -> DocumentEvidence? {
        guard let index else { return nil }
        let scope = context.documentScope(for: target)
        guard !scope.isEmpty else { return nil }
        let readiness = (try? await index.readiness(of: Set(scope.documentIDs.map(\.uuidString)))) ?? [:]
        // Only documents indexed from the file the library holds now may be searched.
        let allowList = Set(scope.live.values.compactMap { live -> String? in
            let id = live.id.uuidString
            guard let state = readiness[id], state.lexicalReady, state.checksum == live.checksum else { return nil }
            return id
        })
        guard !allowList.isEmpty,
              let result = try? await index.search(question, documentIDs: allowList, limit: 8, embedding: provider),
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
