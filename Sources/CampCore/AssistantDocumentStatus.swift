import Foundation

/// Where one document stands for the Assistant, in words the camper sees. The search package reports its own
/// state and the app maps it here, so the wording and the next step live in one tested place.
public enum AssistantDocumentStatus: Equatable, Sendable {
    public enum NoTextCause: Equatable, Sendable {
        case empty, encrypted, unreadable, tooLarge, noText
    }

    /// What the camper can do about it.
    public enum NextAction: Equatable, Sendable {
        /// Nothing to do; the document is usable or will be on its own.
        case none
        /// Indexing or a download is under way. Keep the app open.
        case wait
        /// The file itself is the problem: add a better copy.
        case replaceFile
        /// Another attempt may work.
        case retry
    }

    case queued
    case extracting
    /// Passages written so far out of all of them. Counts, not a time estimate.
    case indexing(done: Int, of: Int)
    case ready
    case readPartially
    case waitingForDownload
    case noUsableText(NoTextCause)
    case englishOnly
    /// Mixed-language: the English passages are used, the rest left out.
    case englishPartial
    case unsupported
    case retryableFailure

    /// Whether the Assistant can answer from this document now.
    public var isUsable: Bool { self == .ready || self == .readPartially || self == .englishPartial }

    /// Not usable yet, but expected to be, or worth another try. A final answer such as "English only" is not.
    public var mayBecomeReady: Bool {
        switch self {
        case .queued, .extracting, .indexing, .waitingForDownload, .retryableFailure: true
        default: false
        }
    }

    public var nextAction: NextAction {
        switch self {
        case .ready, .readPartially, .englishPartial, .englishOnly: .none
        case .queued, .extracting, .indexing, .waitingForDownload: .wait
        case .noUsableText, .unsupported: .replaceFile
        case .retryableFailure: .retry
        }
    }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .extracting: "Reading"
        case .indexing: "Indexing"
        case .ready: "Ready"
        case .readPartially: "Read partially"
        case .waitingForDownload: "Waiting for download"
        case .noUsableText: "No usable text"
        case .englishOnly: "English only"
        case .englishPartial: "English parts only"
        case .unsupported: "Not supported"
        case .retryableFailure: "Couldn’t read yet"
        }
    }

    /// A short phrase for a list of documents: "Service record (being read)".
    public var phrase: String {
        switch self {
        case .queued: "queued"
        case .extracting: "being read"
        case .indexing: "being indexed"
        case .ready: "ready"
        case .readPartially: "read partially"
        case .waitingForDownload: "waiting for download"
        case .noUsableText: "no usable text"
        case .englishOnly: "English only"
        case .englishPartial: "English parts only"
        case .unsupported: "not supported"
        case .retryableFailure: "couldn’t be read yet"
        }
    }

    enum SummaryGroup: CaseIterable {
        case preparing, waiting, retry, unusable, partial
        var text: String {
            switch self {
            case .preparing: "being prepared"
            case .waiting: "waiting for download"
            case .retry: "need a retry"
            case .unusable: "can’t be used"
            case .partial: "read partially"
            }
        }
    }

    var summaryGroup: SummaryGroup? {
        switch self {
        case .ready: nil
        case .queued, .extracting, .indexing: .preparing
        case .waitingForDownload: .waiting
        case .retryableFailure: .retry
        case .noUsableText, .englishOnly, .unsupported: .unusable
        case .readPartially, .englishPartial: .partial
        }
    }

    /// One plain sentence or two: why, and what to do. Nil when there is nothing to add.
    public var guidance: String? {
        switch self {
        case .ready: nil
        case .queued: "Waiting its turn. Nothing to do; the Assistant can’t use it yet."
        case .extracting: "Reading the file. Scans take longer. Nothing to do."
        case .indexing(let done, let total):
            total > 0 ? "Preparing it for search (\(done) of \(total) passages). Nothing to do." : "Preparing it for search. Nothing to do."
        case .readPartially: "Some pages weren’t read, so answers may miss them. A smaller or clearer copy covers the rest."
        case .waitingForDownload: "The file is still arriving from iCloud. Keep the app open and online; it’s read once it lands."
        case .noUsableText(let cause):
            switch cause {
            case .empty: "The PDF has no pages. Replace it with a complete copy."
            case .encrypted: "The PDF needs a password to open. Replace it with a copy that isn’t locked."
            case .unreadable: "The file can’t be opened. Replace it with a good copy."
            case .tooLarge: "The image is too large to read. Replace it with a smaller photo or scan."
            case .noText: "No readable text was found. Replace it with a clearer scan or photo."
            }
        case .englishOnly: "The Assistant only uses English text for now. The file stays here to open and share."
        case .englishPartial: "Only the English passages are used; text in other languages is left out."
        case .unsupported: "The Assistant can’t read this kind of file. Replace it with a PDF or a photo."
        case .retryableFailure: "Reading hit a snag. Try again."
        }
    }
}

/// A document in an Assistant scope, as the library describes it. Holds no file bytes.
public struct ScopedDocument: Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// The details arrived before the file did (iCloud).
    public let waitingForDownload: Bool

    public init(id: UUID, title: String, waitingForDownload: Bool = false) {
        self.id = id; self.title = title; self.waitingForDownload = waitingForDownload
    }

    /// What to show before the index has reported on this document: waiting if its file hasn't arrived, else queued.
    public var fallbackReadiness: AssistantDocumentStatus { waitingForDownload ? .waitingForDownload : .queued }
}

public struct DocumentReadinessEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let readiness: AssistantDocumentStatus

    public init(id: UUID, title: String, readiness: AssistantDocumentStatus) {
        self.id = id; self.title = title; self.readiness = readiness
    }
}

/// Every document a request's scope holds and how ready each was at one moment. A request captures one of these
/// when it is asked, so its answer can say if coverage was incomplete, and a later one can be compared with it.
public struct ScopeReadiness: Equatable, Sendable {
    public static let empty = ScopeReadiness(entries: [])
    static let maximumNamed = 3

    public let entries: [DocumentReadinessEntry]

    public init(entries: [DocumentReadinessEntry]) { self.entries = entries }

    /// `states` holds what the index reports; a document it hasn't reported on yet is queued, or waiting if
    /// its file hasn't arrived. Entries are ordered by title so the list doesn't shuffle as states change.
    public static func make(documents: [ScopedDocument], states: [UUID: AssistantDocumentStatus]) -> ScopeReadiness {
        ScopeReadiness(entries: documents
            .map { DocumentReadinessEntry(id: $0.id, title: $0.title, readiness: states[$0.id] ?? $0.fallbackReadiness) }
            .sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            })
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var usableCount: Int { entries.filter(\.readiness.isUsable).count }
    /// Documents that can't support an answer now.
    public var unusable: [DocumentReadinessEntry] { entries.filter { !$0.readiness.isUsable } }
    /// Documents that are not fully covered: unusable ones and those read partially.
    public var gaps: [DocumentReadinessEntry] { entries.filter { $0.readiness != .ready } }
    /// Every document in scope is ready and fully read.
    public var isComplete: Bool { gaps.isEmpty }
    public var hasUnusableDocuments: Bool { entries.contains { !$0.readiness.isUsable } }

    /// Documents that could not support an answer in `earlier` and can now.
    public func newlyReady(since earlier: ScopeReadiness) -> [DocumentReadinessEntry] {
        let before = Dictionary(earlier.entries.map { ($0.id, $0.readiness) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { entry in
            guard entry.readiness.isUsable, let was = before[entry.id] else { return false }
            return !was.isUsable
        }
    }

    /// "2 of 3 documents ready · 1 being read", or nil when the scope holds no documents.
    public var summary: String? {
        guard !entries.isEmpty else { return nil }
        guard !isComplete || entries.count > 1 else { return "1 document ready" }
        if isComplete { return "All \(entries.count) documents ready" }
        var parts = ["\(usableCount) of \(entries.count) documents ready"]
        for group in AssistantDocumentStatus.SummaryGroup.allCases {
            let count = entries.filter { $0.readiness.summaryGroup == group }.count
            if count > 0 { parts.append("\(count) \(group.text)") }
        }
        return parts.joined(separator: " · ")
    }

    /// Names for a sentence: "A (being read), B (queued) and 2 more". Titles come from the camper's files.
    func named(_ items: [DocumentReadinessEntry], title: (String) -> String = { $0 }) -> String {
        let shown = items.prefix(Self.maximumNamed).map { "\(title($0.title)) (\($0.readiness.phrase))" }
        let more = items.count - shown.count
        var list = shown.joined(separator: ", ")
        if more > 0 { list += " and \(more) more" }
        return list
    }

    /// Shown with an answer given while some documents were not fully covered. Nil when coverage was complete.
    public var incompleteNote: String? {
        guard !gaps.isEmpty else { return nil }
        return "Not every document was searched: \(named(gaps)). This answer may be missing what they say."
    }

    /// Shown instead of a "not covered" claim when nothing relevant was found but some documents weren't usable.
    public var cannotSupportNote: String? {
        let missing = unusable
        guard !missing.isEmpty else { return nil }
        let pending = missing.contains { $0.readiness.mayBecomeReady }
        return pending
            ? "I can’t yet support an answer from every document: \(named(missing)). Ask again once they’re ready."
            : "Some documents can’t be used: \(named(missing)). Nothing from them is in this answer."
    }

    /// What a request tells the model about documents it could not read, so it won't guess at their contents.
    public func promptNote(sanitizing title: (String) -> String) -> String? {
        let missing = unusable
        guard !missing.isEmpty else { return nil }
        return "These documents could not be searched: \(named(missing, title: title)). Their contents are unknown. If the question may depend on them, say first that you can't support an answer from them yet, and state no fact, number, or time as coming from them."
    }
}
