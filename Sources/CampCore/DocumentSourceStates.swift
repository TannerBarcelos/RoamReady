import Foundation

/// What the library says about a cited document when the camper taps its source.
public enum SourceAvailability: Equatable, Sendable {
    /// Same file the passage was read from.
    case current
    /// Replaced since the answer: the cited page may not match the file now.
    case changed
    /// No longer in the library.
    case deleted
    /// Still the same file, but its bytes haven't arrived on this device yet.
    case notDownloaded
}

/// A document as it is right now, captured on the model context's actor.
public struct LiveSourceDocument: Equatable, Sendable {
    public let checksum: String?
    public let hasLocalContent: Bool

    public init(checksum: String?, hasLocalContent: Bool) {
        self.checksum = checksum; self.hasLocalContent = hasLocalContent
    }
}

public enum SourceResolution {
    /// A changed or deleted document is never reported as current, so the viewer can't open another file at an old citation.
    public static func availability(of source: DocumentSource, live: LiveSourceDocument?) -> SourceAvailability {
        guard let live else { return .deleted }
        guard live.checksum == source.checksum else { return .changed }
        return live.hasLocalContent ? .current : .notDownloaded
    }
}

/// How an answer's document sources are laid out under it. Cited sources and references searched are separate
/// groups, and an answer with nothing cited carries a note saying why instead of an empty list.
public struct AnswerSources: Equatable, Sendable {
    public enum Note: Equatable, Sendable {
        /// Documents were searched and none was relevant.
        case notCovered
        /// Relevant excerpts were supplied but none was cited.
        case generalAdvice
        /// No documents were in scope.
        case noDocuments
    }

    public let cited: [DocumentSource]
    /// Retrieved and given to the model, but not cited. Never described as used.
    public let searched: [DocumentSource]
    public let note: Note?

    public init(coverage: DocumentCoverage, cited: [DocumentSource], searched: [DocumentSource]) {
        self.cited = cited
        self.searched = searched
        if !cited.isEmpty {
            note = nil
        } else {
            switch coverage {
            case .notSearched: note = .noDocuments
            case .notCovered: note = .notCovered
            // The readiness note already explains an answer that couldn't yet use every document.
            case .unfinished: note = nil
            case .uncited, .cited: note = .generalAdvice
            }
        }
    }

    public static func text(for note: Note) -> String {
        switch note {
        case .notCovered: "Your documents don’t cover this."
        case .generalAdvice: "General advice. No document was cited."
        case .noDocuments: "General advice. No documents were searched."
        }
    }
}
