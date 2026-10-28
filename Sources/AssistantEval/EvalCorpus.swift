import Foundation

/// The versioned synthetic corpus: invented rigs, trips, and paperwork, plus the questions asked of them and
/// the evidence each answer needs. Labels name a document, its version, a page, and a quoted span. They never
/// name a chunk, so changing the chunker doesn't invalidate them.
public struct EvalCorpus: Codable, Equatable, Sendable {
    public struct Rig: Codable, Equatable, Sendable { public var id: String; public var name: String }
    public struct Trip: Codable, Equatable, Sendable { public var id: String; public var name: String; public var rig: String }

    public struct Page: Codable, Equatable, Sendable {
        public var ordinal: Int
        public var label: String?
        public var text: String
    }

    public enum Status: String, Codable, Sendable {
        case present, deleted
        /// Details synced but the file's bytes haven't arrived, so nothing was extracted or indexed.
        case bytesUnavailable
    }

    public struct Document: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var category: String
        /// The version in the library now. A document's checksum is `id@version`.
        public var version: String
        /// The version the index holds, when it lags the library (a replaced file not yet re-indexed).
        public var indexedVersion: String?
        public var status: Status?
        /// "rig:<id>", "trip:<id>", or "unattached".
        public var owner: String
        /// Where the index last knew the document to be, when it has since moved.
        public var indexedOwner: String?
        public var optedIn: Bool?
        public var ocrNoise: Bool?
        /// The pages of the indexed version.
        public var pages: [Page]

        public var liveChecksum: String { "\(id)@\(version)" }
        public var indexedChecksum: String { "\(id)@\(indexedVersion ?? version)" }
        public var liveStatus: Status { status ?? .present }
        /// What the index can hold: a document whose bytes never arrived was never extracted.
        public var isIndexed: Bool { liveStatus != .bytesUnavailable }
    }

    public struct Scope: Codable, Equatable, Sendable {
        public var rig: String?
        public var trip: String?
    }

    public struct Span: Codable, Equatable, Sendable {
        public var document: String
        public var version: String
        public var page: Int
        public var quote: String
    }

    /// One thing the answer needs. Any one of its spans satisfies it (the same fact stated in two places).
    public struct EvidenceGroup: Codable, Equatable, Sendable {
        public var id: String
        public var anyOf: [Span]
    }

    public enum Subset: String, Codable, Sendable, CaseIterable { case dev, heldout }
    public enum Kind: String, Codable, Sendable { case required, challenge }

    public struct Case: Codable, Equatable, Sendable {
        public var id: String
        public var subset: Subset
        /// Required cases gate a release. Challenge cases are known-hard or wait on a feature, and are reported apart.
        public var kind: Kind
        public var tags: [String]?
        public var question: String
        public var scope: Scope
        /// Simulates the library changing after the search's allow-list was captured, so the live check is what keeps
        /// a moved, deleted, or opted-out document out of the answer.
        public var staleAllowList: Bool?
        public var answerable: Bool
        public var evidence: [EvidenceGroup]?
        /// A fault code, part number, or access code the answer depends on.
        public var exactCode: String?
        /// Text that appears only inside the document and must never reach the model's instructions.
        public var injectionMarkers: [String]?
        /// Forged source IDs or delimiters inside the document that must not reach the prompt verbatim.
        public var forgedMarkers: [String]?
        public var compactRetry: Bool?
        public var pendingFeature: String?
        public var notes: String?
    }

    public var version: String
    public var synthetic: Bool
    public var description: String
    public var rigs: [Rig]
    public var trips: [Trip]
    public var documents: [Document]
    public var cases: [Case]

    // MARK: Loading

    public static func load(from url: URL) throws -> EvalCorpus {
        try validated(JSONDecoder().decode(EvalCorpus.self, from: Data(contentsOf: url)))
    }

    /// The corpus shipped with the repository.
    public static func bundled() throws -> EvalCorpus {
        guard let url = Bundle.module.url(forResource: "corpus-v1", withExtension: "json", subdirectory: "Corpus") else {
            throw EvalError.corpus("corpus-v1.json is missing from the bundle")
        }
        return try load(from: url)
    }

    public static func validated(_ corpus: EvalCorpus) throws -> EvalCorpus {
        try corpus.validate()
        return corpus
    }

    public func document(_ id: String) -> Document? { documents.first { $0.id == id } }

    // MARK: Validation

    private static let categories: Set<String> = ["Manual", "Service & maintenance", "Warranty", "Reservation", "Registration", "Insurance", "Other"]

    func validate() throws {
        guard synthetic else { throw EvalError.corpus("The corpus must be synthetic.") }
        try unique(documents.map(\.id), "document")
        try unique(cases.map(\.id), "case")
        try unique(rigs.map(\.id), "rig")
        try unique(trips.map(\.id), "trip")
        for trip in trips where !rigs.contains(where: { $0.id == trip.rig }) {
            throw EvalError.corpus("Trip \(trip.id) names an unknown rig.")
        }
        for doc in documents {
            guard Self.categories.contains(doc.category) else { throw EvalError.corpus("\(doc.id): unknown category \(doc.category).") }
            for owner in [doc.owner, doc.indexedOwner].compactMap({ $0 }) where !isValidOwner(owner) {
                throw EvalError.corpus("\(doc.id): unknown owner \(owner).")
            }
        }
        for item in cases {
            if let rig = item.scope.rig, !rigs.contains(where: { $0.id == rig }) { throw EvalError.corpus("\(item.id): unknown rig.") }
            if let trip = item.scope.trip, !trips.contains(where: { $0.id == trip }) { throw EvalError.corpus("\(item.id): unknown trip.") }
            guard (item.scope.rig == nil) != (item.scope.trip == nil) else { throw EvalError.corpus("\(item.id): scope needs exactly one of rig or trip.") }
            let groups = item.evidence ?? []
            guard item.answerable == !groups.isEmpty else { throw EvalError.corpus("\(item.id): answerable cases need evidence and unanswerable ones none.") }
            for group in groups {
                guard !group.anyOf.isEmpty else { throw EvalError.corpus("\(item.id)/\(group.id): empty evidence group.") }
                for span in group.anyOf { _ = try range(of: span, in: item.id) }
            }
        }
    }

    private func isValidOwner(_ owner: String) -> Bool {
        if owner == "unattached" { return true }
        if owner.hasPrefix("rig:") { return rigs.contains { $0.id == String(owner.dropFirst(4)) } }
        if owner.hasPrefix("trip:") { return trips.contains { $0.id == String(owner.dropFirst(5)) } }
        return false
    }

    private func unique(_ ids: [String], _ what: String) throws {
        if Set(ids).count != ids.count { throw EvalError.corpus("Duplicate \(what) ID.") }
    }

    // MARK: Evidence units

    /// A labeled span located in its page: the character range of its quote in the whitespace-normalized page text.
    struct LocatedSpan {
        var span: Span
        var range: Range<Int>
    }

    /// What Recall@5 counts: a group of interchangeable spans. Groups whose spans overlap in a page are one unit,
    /// so two labels on the same sentence can't be counted twice.
    struct EvidenceUnit {
        var ids: [String]
        var spans: [LocatedSpan]
    }

    func range(of span: Span, in caseID: String) throws -> Range<Int> {
        guard let doc = document(span.document) else { throw EvalError.corpus("\(caseID): unknown document \(span.document).") }
        guard span.version == doc.indexedVersion ?? doc.version else {
            throw EvalError.corpus("\(caseID): \(span.document) is labeled at \(span.version) but the indexed version is \(doc.indexedVersion ?? doc.version).")
        }
        guard let page = doc.pages.first(where: { $0.ordinal == span.page }) else {
            throw EvalError.corpus("\(caseID): \(span.document) has no page \(span.page).")
        }
        let text = Self.normalized(page.text), quote = Self.normalized(span.quote)
        guard !quote.isEmpty, let found = text.range(of: quote) else {
            throw EvalError.corpus("\(caseID): the quote \"\(span.quote)\" is not on \(span.document) page \(span.page).")
        }
        guard text.range(of: quote, range: found.upperBound..<text.endIndex) == nil else {
            throw EvalError.corpus("\(caseID): the quote \"\(span.quote)\" is not unique on \(span.document) page \(span.page).")
        }
        return text.distance(from: text.startIndex, to: found.lowerBound)..<text.distance(from: text.startIndex, to: found.upperBound)
    }

    func units(for item: Case) throws -> [EvidenceUnit] {
        var units: [EvidenceUnit] = try (item.evidence ?? []).map { group in
            EvidenceUnit(ids: [group.id], spans: try group.anyOf.map { LocatedSpan(span: $0, range: try range(of: $0, in: item.id)) })
        }
        // Merge until no two units share an overlapping span.
        var merged = true
        while merged {
            merged = false
            outer: for i in units.indices {
                for j in units.indices where j > i && units[i].overlaps(units[j]) {
                    units[i].ids += units[j].ids
                    units[i].spans += units[j].spans
                    units.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return units
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension EvalCorpus.EvidenceUnit {
    func overlaps(_ other: EvalCorpus.EvidenceUnit) -> Bool {
        spans.contains { a in
            other.spans.contains { b in
                a.span.document == b.span.document && a.span.page == b.span.page && a.range.overlaps(b.range)
            }
        }
    }
}

public enum EvalError: Error, CustomStringConvertible {
    case corpus(String)
    public var description: String {
        switch self { case .corpus(let message): return message }
    }
}
