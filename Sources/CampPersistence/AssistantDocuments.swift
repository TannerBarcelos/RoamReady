import Foundation
import SwiftData
import CampCore
import DocumentVault

/// Which documents the Assistant may read. This is the one place the rule lives, so later scopes (a trip's
/// own documents, the Other opt-in, assignment) extend it rather than adding second copies.
public enum AssistantDocumentEligibility {
    /// Included by default. Registration and Insurance are never included; Other is off until the owner
    /// opts a document in, which is not built yet, so it stays out.
    public static let searchableCategories: Set<DocumentCategory> = [.manual, .maintenance, .warranty, .reservation]

    /// A document the Assistant can read has a searchable category and original text stored on this device.
    /// Only PDFs are read so far; photographed paperwork needs text recognition, which comes later.
    public static func isSearchable(category: DocumentCategory, file: DocumentFile?, availability: DocumentAvailability) -> Bool {
        searchableCategories.contains(category) && availability == .offline && file?.contentType == .pdf
    }
}

public extension StoredDocument {
    /// Eligible by category and content, wherever it is attached.
    var isAssistantSearchable: Bool {
        !isDeleted && AssistantDocumentEligibility.isSearchable(category: category, file: file, availability: availability)
    }

    /// What the general Assistant may search for this rig: eligible documents attached directly to it.
    /// A document that belongs to a trip, or to nothing, is out of scope.
    func isInGeneralScope(of rig: Rig) -> Bool {
        isAssistantSearchable && self.rig === rig && trip == nil
    }
}

/// The allow-list for one question, and the live facts needed to re-check it after searching.
public struct AssistantDocumentScope: Sendable {
    /// Documents in scope, by ID.
    public let live: [UUID: LiveDocument]
    public var documentIDs: Set<UUID> { Set(live.keys) }
    public var isEmpty: Bool { live.isEmpty }
}

public extension Rig {
    /// Reads the library now. Call it again right before building a prompt instead of trusting an earlier result.
    func generalAssistantScope() -> AssistantDocumentScope {
        let documents = (self.documents ?? []).filter { $0.isInGeneralScope(of: self) }
        return AssistantDocumentScope(live: Dictionary(documents.map {
            ($0.documentID, LiveDocument(id: $0.documentID, title: $0.title, category: $0.category.title,
                                         checksum: $0.checksum, isInScope: true))
        }, uniquingKeysWith: { first, _ in first }))
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
