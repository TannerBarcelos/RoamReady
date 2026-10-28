import Foundation

/// Where one document stands in the Assistant's index. A Sendable value, so a later screen can show it.
public enum DocumentIndexState: Equatable, Sendable {
    case queued
    case extracting
    /// Passages written so far out of all of them. Counts, not a time estimate.
    case indexing(done: Int, of: Int)
    case ready
    /// The details arrived (iCloud) before the file. This is waiting, not a failure.
    case waitingForDownload
    case noUsableText
    /// The text is not English, which document answers do not use yet.
    case englishOnly
    /// A kind of file the Assistant can't read.
    case unsupported
    /// Reading or indexing failed in a way another try may fix.
    case retryableFailure
}

/// A document the library holds that the Assistant could read, as the library describes it now.
public struct LibraryDocument: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case ready
        case waitingForDownload
        case unsupported
    }

    public var id: String
    public var checksum: String
    public var availability: Availability

    public init(id: String, checksum: String, availability: Availability) {
        self.id = id
        self.checksum = checksum
        self.availability = availability
    }
}

/// What reading one document produced. Foundation-only, so extraction (PDFKit, text recognition) stays in the app.
public struct ExtractedDocument: Equatable, Sendable {
    public var pages: [ExtractedPage]
    public var language: String
    public var isEnglish: Bool

    public init(pages: [ExtractedPage], language: String, isEnglish: Bool) {
        self.pages = pages
        self.language = language
        self.isEnglish = isEnglish
    }
}

public enum DocumentReadResult: Equatable, Sendable {
    case text(ExtractedDocument)
    case noUsableText
    /// The bytes aren't on this device yet.
    case waitingForDownload
    /// The library no longer holds the file this was asked to read. The next pass sees the new one.
    case changed
}

/// The library as the coordinator sees it. The app implements this over SwiftData; tests implement it directly.
public protocol DocumentIndexSource: Sendable {
    /// Every document the Assistant could ever read, with no file bytes loaded.
    func library() async throws -> [LibraryDocument]
    /// Reads one document's text. Throwing means a failure another attempt may fix.
    func read(_ document: LibraryDocument) async throws -> DocumentReadResult
}

/// What a reconciliation pass does, decided from metadata alone so it stays cheap however large the library is.
public struct ReconciliationPlan: Equatable, Sendable {
    /// Indexed documents to drop: gone from the library, no longer readable, or replaced by a file that isn't
    /// on this device yet (the old generation can't be current any more).
    public var remove: [String]
    /// Documents to read and index, in library order.
    public var index: [LibraryDocument]
    /// The state of every document in the library. Those in `index` are `queued`.
    public var states: [String: DocumentIndexState]

    public static func make(library: [LibraryDocument], indexed: [String: IndexedDocumentRecord], extractionVersion: Int,
                            exhausted: Set<String> = []) -> ReconciliationPlan {
        var plan = ReconciliationPlan(remove: [], index: [], states: [:])
        let libraryIDs = Set(library.map(\.id))
        plan.remove = indexed.keys.filter { !libraryIDs.contains($0) }.sorted()
        for document in library {
            let record = indexed[document.id]
            switch document.availability {
            case .unsupported:
                plan.states[document.id] = .unsupported
                if record != nil { plan.remove.append(document.id) }
            case .waitingForDownload:
                plan.states[document.id] = .waitingForDownload
                if let record, record.checksum != document.checksum { plan.remove.append(document.id) }
            case .ready:
                if let record, record.isCurrent(checksum: document.checksum, extractionVersion: extractionVersion) {
                    plan.states[document.id] = switch record.outcome {
                    case .ready: .ready
                    case .noUsableText: .noUsableText
                    case .englishOnly: .englishOnly
                    }
                } else if exhausted.contains(document.id) {
                    plan.states[document.id] = .retryableFailure
                } else {
                    plan.states[document.id] = .queued
                    plan.index.append(document)
                }
            }
        }
        return plan
    }
}
