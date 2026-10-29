import Foundation
import SwiftData
import CampCore
import DocumentVault

/// Which documents the Assistant may read. This is the one place the rule lives, so later scopes (a trip's
/// own documents, assignment) extend it rather than adding second copies.
public enum AssistantDocumentEligibility {
    /// Included by default. Registration and Insurance are never included, even if a stale opt-in or index
    /// row exists. Other is included only when the owner opts that document in.
    public static let searchableCategories: Set<DocumentCategory> = [.manual, .maintenance, .warranty, .reservation]

    /// Formats the reader can open: PDFs (text layer, with text recognition for pages that have none) and
    /// image documents (text recognition). The reader reports a file it still can't use as having no usable
    /// text, so listing a format here never loops on a bad file.
    public static let readableContentTypes: Set<DocumentContentType> = Set(DocumentContentType.allCases)

    /// Only Other documents can be opted in.
    public static func isEligible(category: DocumentCategory, includeInAssistant: Bool) -> Bool {
        searchableCategories.contains(category) || (category == .other && includeInAssistant)
    }

    /// A document the Assistant can read has an eligible category, a readable format, and original bytes
    /// stored on this device. A link without a saved copy has no file, so it never qualifies.
    public static func isSearchable(category: DocumentCategory, includeInAssistant: Bool = false, file: DocumentFile?,
                                    availability: DocumentAvailability) -> Bool {
        isEligible(category: category, includeInAssistant: includeInAssistant) && availability == .offline
            && file.map { readableContentTypes.contains($0.contentType) } == true
    }
}

public extension StoredDocument {
    /// Eligible by category and content, wherever it is attached.
    var isAssistantSearchable: Bool {
        !isDeleted && AssistantDocumentEligibility.isSearchable(category: category, includeInAssistant: includeInAssistant, file: file, availability: availability)
    }

    /// What the general Assistant may search for this rig: eligible documents attached directly to it.
    /// A document that belongs to a trip, or to nothing, is out of scope.
    func isInGeneralScope(of rig: Rig) -> Bool {
        isAssistantSearchable && self.rig === rig && trip == nil
    }

    /// What Assistant help from a trip may search: the trip's own eligible documents, and eligible documents
    /// attached directly to the trip's rig (archived or not). Another trip's documents are never in scope.
    func isInTripScope(of trip: Trip) -> Bool {
        guard isAssistantSearchable else { return false }
        if self.trip != nil { return self.trip === trip }
        return rig != nil && rig === trip.rig
    }
}

/// The allow-list for one question, and the live facts needed to re-check it after searching.
public struct AssistantDocumentScope: Sendable {
    /// Documents in scope, by ID.
    public let live: [UUID: LiveDocument]
    public var documentIDs: Set<UUID> { Set(live.keys) }
    public var isEmpty: Bool { live.isEmpty }

    static let empty = AssistantDocumentScope(live: [:])

    init(live: [UUID: LiveDocument]) { self.live = live }

    init(_ documents: [StoredDocument]) {
        live = Dictionary(documents.map {
            ($0.documentID, LiveDocument(id: $0.documentID, title: $0.title, category: $0.category.title,
                                         checksum: $0.checksum, isInScope: true))
        }, uniquingKeysWith: { first, _ in first })
    }
}

public extension Rig {
    /// Reads the library now. Call it again right before building a prompt instead of trusting an earlier result.
    func generalAssistantScope() -> AssistantDocumentScope {
        AssistantDocumentScope((documents ?? []).filter { $0.isInGeneralScope(of: self) })
    }
}

public extension Trip {
    /// Reads the library now, like `Rig.generalAssistantScope()`.
    func tripAssistantScope() -> AssistantDocumentScope {
        let own = (documents ?? []).filter { $0.isInTripScope(of: self) }
        let fromRig = (rig?.documents ?? []).filter { $0.isInTripScope(of: self) }
        return AssistantDocumentScope(own + fromRig)
    }
}

/// Which rig, and which trip if any, a request is for. Captured when the question is asked and used for the
/// whole request, so a rig switch or navigation while it runs can't change what it searches.
/// Identity is the models' persistent IDs; renaming a rig or trip doesn't make it a different scope.
public struct AssistantScopeTarget: Hashable, Sendable {
    public let rigID: PersistentIdentifier?
    public let tripID: PersistentIdentifier?
    public let summary: AssistantScopeSummary

    public var isTrip: Bool { tripID != nil }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rigID == rhs.rigID && lhs.tripID == rhs.tripID }
    public func hash(into hasher: inout Hasher) { hasher.combine(rigID); hasher.combine(tripID) }

    /// General Assistant: the active rig only. Pass nil when there is none.
    public static func general(rig: Rig?) -> AssistantScopeTarget {
        AssistantScopeTarget(rigID: rig?.persistentModelID, tripID: nil,
                             summary: AssistantScopeSummary(rigName: rig?.displayName, rigIsArchived: rig?.isArchived ?? false))
    }

    public static func trip(_ trip: Trip) -> AssistantScopeTarget {
        AssistantScopeTarget(rigID: trip.rig?.persistentModelID, tripID: trip.persistentModelID,
                             summary: AssistantScopeSummary(rigName: trip.rig?.displayName, tripName: trip.campgroundName,
                                                            rigIsArchived: trip.rig?.isArchived ?? false))
    }
}

public extension ModelContext {
    /// The documents a request for this target may search, read from the library now. Only the target's own IDs
    /// are used. General Assistant never reads a trip's documents, and refuses a rig that has been archived or
    /// deleted since the question was asked.
    func documentScope(for target: AssistantScopeTarget) -> AssistantDocumentScope {
        if let tripID = target.tripID {
            var descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.persistentModelID == tripID })
            descriptor.fetchLimit = 1
            guard let trip = (try? fetch(descriptor))?.first, !trip.isDeleted else { return .empty }
            // A trip moved to another rig is a different scope; don't answer from the new rig's documents.
            guard trip.rig?.persistentModelID == target.rigID else { return .empty }
            return trip.tripAssistantScope()
        }
        guard let rigID = target.rigID else { return .empty }
        var descriptor = FetchDescriptor<Rig>(predicate: #Predicate { $0.persistentModelID == rigID })
        descriptor.fetchLimit = 1
        guard let rig = (try? fetch(descriptor))?.first, !rig.isDeleted, !rig.isArchived else { return .empty }
        return rig.generalAssistantScope()
    }
}

/// A document's original bytes, captured on the model context's actor so reading and indexing can happen
/// elsewhere. Holds no model instance.
public struct DocumentIndexJob: Sendable {
    public let documentID: UUID
    public let checksum: String
    public let content: DocumentContentSnapshot
}

/// A cheap listing: no file bytes are loaded.
public struct IndexableDocument: Sendable, Equatable {
    public let documentID: UUID
    public let checksum: String
}

public extension ModelContext {
    /// Every document the Assistant could ever read, wherever it is attached.
    func indexableDocuments() throws -> [IndexableDocument] {
        try fetch(FetchDescriptor<StoredDocument>()).compactMap {
            guard $0.isAssistantSearchable, let checksum = $0.checksum else { return nil }
            return IndexableDocument(documentID: $0.documentID, checksum: checksum)
        }
    }

    /// Captures one document's bytes for indexing, or nil if it is gone, changed, or not yet downloaded.
    func indexJob(documentID: UUID, checksum: String) throws -> DocumentIndexJob? {
        var descriptor = FetchDescriptor<StoredDocument>(predicate: #Predicate { $0.documentID == documentID })
        descriptor.fetchLimit = 1
        guard let document = try fetch(descriptor).first, document.isAssistantSearchable, document.checksum == checksum,
              let content = try? document.contentSnapshot() else { return nil }
        return DocumentIndexJob(documentID: documentID, checksum: checksum, content: content)
    }

    /// The live document with this ID, for opening a cited source.
    func document(withID documentID: UUID) -> StoredDocument? {
        var descriptor = FetchDescriptor<StoredDocument>(predicate: #Predicate { $0.documentID == documentID })
        descriptor.fetchLimit = 1
        return (try? fetch(descriptor))?.first
    }
}
