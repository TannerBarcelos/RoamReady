import Foundation

/// The result of one eval run: what was configured, per-case outcomes, and aggregates. Required cases and
/// challenge cases are aggregated separately, so a hard or not-yet-built case can't lower the release score or hide inside it.
public struct EvalReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case passed, failed
        /// The model or embedding the run needs isn't on this machine. Never a pass.
        case notRun = "not run"
    }

    public struct Metadata: Codable, Equatable, Sendable {
        public var corpusVersion: String
        public var corpusChecksum: String
        public var commit: String?
        public var operatingSystem: String
        public var hardware: String
        /// "lexical-only", or the embedding revision and dimension the vectors came from.
        public var retrieval: String
        public var embeddingRevision: String?
        public var embeddingDimension: Int?
        public var extractionVersion: Int
        public var chunkingVersion: Int
        public var indexSchemaVersion: Int
        public var sqliteVecVersion: String
        public var ranker: String
        public var evidenceLimits: String
        public var subsets: [String]
        public var generatedAt: Date
    }

    public struct GenerationStatus: Codable, Equatable, Sendable {
        public var status: String
        public var reason: String
    }

    public struct Aggregate: Codable, Equatable, Sendable {
        public var cases = 0
        public var answerable = 0
        public var unanswerable = 0
        public var passed = 0
        /// Answerable cases with at least one labeled unit in the top 5, over answerable cases.
        public var hitAt5: Double?
        /// Mean over answerable cases of (labeled units found in the top 5) / (labeled units in the case).
        public var recallAt5: Double?
        public var unitsCovered = 0
        public var unitsTotal = 0
        /// Mean reciprocal rank of the first labeled passage, over answerable cases only (0 when never retrieved).
        public var mrr: Double?
        public var exactCodeCases = 0
        public var exactCodeSuccesses = 0
        public var exactCodeSuccess: Double?
        public var scopeViolations = 0
        public var staleEvidence = 0
        public var noEvidenceFalsePositives = 0
        /// False positives over unanswerable cases.
        public var falsePositiveRate: Double?
        public var citationInvalidCases = 0
        /// Cases whose citations all resolve to live, in-scope sources of the right version, over all cases.
        public var citationValidity: Double?
        public var promptFailures = 0
        public var failedCases: [String] = []
    }

    public struct Violation: Codable, Equatable, Sendable {
        public var document: String
        public var title: String
        public var page: Int?
        public var reason: String
    }

    public struct ExpectedUnit: Codable, Equatable, Sendable {
        public var evidence: [String]
        /// Any one of these satisfies the unit.
        public var spans: [String]
        public var coveredInTop5: Bool
        public var coveredByPrompt: Bool
    }

    public struct SearchResultRow: Codable, Equatable, Sendable {
        /// Rank among live, in-scope hits, or nil when the live check dropped it.
        public var rank: Int?
        public var document: String
        public var title: String
        public var version: String
        public var page: Int?
        public var excerpt: String
        public var matchedLexically: Bool
        public var matchedByVector: Bool
        public var covers: [String]
        public var droppedBy: String?
    }

    public struct EvidenceRow: Codable, Equatable, Sendable {
        public var source: String
        public var document: String
        public var title: String
        public var version: String
        public var page: Int?
        public var excerpt: String
        public var covers: [String]
    }

    public struct CaseResult: Codable, Equatable, Sendable {
        public var id: String
        public var subset: String
        public var kind: String
        public var tags: [String]
        public var pendingFeature: String?
        public var notes: String?
        public var question: String
        public var scope: String
        public var answerable: Bool
        public var passed: Bool
        public var expected: [ExpectedUnit]
        public var search: [SearchResultRow]
        public var evidence: [EvidenceRow]
        public var hitAt5: Bool?
        public var recallAt5: Double?
        public var reciprocalRank: Double?
        public var unitsCovered: Int
        public var unitsTotal: Int
        public var exactCode: String?
        public var exactCodeSuccess: Bool?
        public var scopeViolations: [Violation]
        public var staleEvidence: [Violation]
        /// Passages the search returned that the live library no longer allows. Informational: the live check worked.
        public var droppedByLiveCheck: [Violation]
        public var noEvidenceFalsePositive: Bool
        public var citationFailures: [String]
        public var promptFailures: [String]
        public var failures: [String]
    }

    public var outcome: Outcome
    public var notRunReason: String?
    public var metadata: Metadata
    public var generation: GenerationStatus
    public var required: Aggregate
    public var requiredDev: Aggregate
    public var requiredHeldOut: Aggregate
    public var challenge: Aggregate
    public var cases: [CaseResult]

    // MARK: Output

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EvalReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvalReport.self, from: data)
    }

    public func markdown() -> String {
        var out = "# Document Assistant retrieval eval\n\n"
        out += "**Outcome: \(outcome.rawValue.uppercased())**"
        if let notRunReason { out += " — \(notRunReason)" }
        out += "\n\n"
        out += metadataTable()
        out += "\n**Generation:** \(generation.status) — \(generation.reason)\n\n"
        guard outcome != .notRun else { return out }

        out += "## Aggregates\n\n"
        out += "Required cases gate a release; challenge cases are known-hard or wait on a feature and are reported apart.\n\n"
        let rows: [(String, Aggregate)] = [("Required, all", required), ("Required, dev", requiredDev),
                                           ("Required, held-out", requiredHeldOut), ("Challenge", challenge)]
        out += "| Metric | " + rows.map(\.0).joined(separator: " | ") + " |\n|---|" + rows.map { _ in "---:|" }.joined() + "\n"
        func row(_ name: String, _ value: (Aggregate) -> String) {
            out += "| \(name) | " + rows.map { value($0.1) }.joined(separator: " | ") + " |\n"
        }
        row("Cases passed") { "\($0.passed) / \($0.cases)" }
        row("Answerable / unanswerable") { "\($0.answerable) / \($0.unanswerable)" }
        row("Hit@5") { Self.percent($0.hitAt5) }
        row("Recall@5") { Self.percent($0.recallAt5) + ($0.unitsTotal > 0 ? " (\($0.unitsCovered)/\($0.unitsTotal) units)" : "") }
        row("MRR (answerable only)") { $0.mrr.map { String(format: "%.3f", $0) } ?? "n/a" }
        row("Exact-code success") { Self.percent($0.exactCodeSuccess) + ($0.exactCodeCases > 0 ? " (\($0.exactCodeSuccesses)/\($0.exactCodeCases))" : "") }
        row("Scope / exclusion violations") { "\($0.scopeViolations)" }
        row("Stale evidence") { "\($0.staleEvidence)" }
        row("No-evidence false positives") { "\($0.noEvidenceFalsePositives)" + ($0.unanswerable > 0 ? " / \($0.unanswerable)" : "") }
        row("Citation validity") { Self.percent($0.citationValidity) }
        row("Prompt-safety failures") { "\($0.promptFailures)" }

        out += """

        **Definitions.** Hit@5: the share of answerable cases with at least one labeled passage in the top 5 live, in-scope results. \
        Recall@5: per case, labeled evidence units found in the top 5 divided by the units the case labels, averaged over answerable \
        cases; labels whose spans overlap in the same page are merged into one unit, and a unit counts once however many passages cover it. \
        MRR: the mean of 1/rank of the first labeled passage over answerable cases only. Unanswerable cases appear only in the \
        false-positive and violation counts.

        """

        out += "\n## Cases\n\n| Case | Subset | Kind | Result | Hit@5 | Recall@5 | RR | Notes |\n|---|---|---|---|---:|---:|---:|---|\n"
        for item in cases.sorted(by: { ($0.kind, $0.id) < ($1.kind, $1.id) }) {
            let note = [item.pendingFeature.map { "pending: \($0)" },
                        item.scopeViolations.isEmpty ? nil : "\(item.scopeViolations.count) scope violation(s)",
                        item.staleEvidence.isEmpty ? nil : "\(item.staleEvidence.count) stale",
                        item.noEvidenceFalsePositive ? "false positive" : nil,
                        item.citationFailures.isEmpty ? nil : "citation invalid",
                        item.promptFailures.isEmpty ? nil : "prompt unsafe"].compactMap { $0 }.joined(separator: "; ")
            out += "| `\(item.id)` | \(item.subset) | \(item.kind) | \(item.passed ? "pass" : "**FAIL**") | "
            out += "\(item.hitAt5.map { $0 ? "yes" : "no" } ?? "–") | \(item.recallAt5.map { String(format: "%.2f", $0) } ?? "–") | "
            out += "\(item.reciprocalRank.map { String(format: "%.2f", $0) } ?? "–") | \(note) |\n"
        }

        let failing = cases.filter { !$0.passed }.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
        out += "\n## Failures and misses\n\n"
        if failing.isEmpty { out += "None.\n" }
        for item in failing {
            out += "### `\(item.id)` (\(item.kind), \(item.subset))\n\n"
            out += "Question: \(item.question) — scope: \(item.scope)\n\n"
            for failure in item.failures { out += "- \(failure)\n" }
            out += "\n"
            out += Self.evidenceDetail(item)
        }

        out += "\n## Expected and actual evidence, every case\n\n"
        for item in cases.sorted(by: { ($0.kind, $0.id) < ($1.kind, $1.id) }) {
            out += "### `\(item.id)` — \(item.passed ? "pass" : "FAIL")\n\n" + Self.evidenceDetail(item)
        }
        return out
    }

    private static func evidenceDetail(_ item: CaseResult) -> String {
        var out = ""
        if item.expected.isEmpty {
            out += "Expected: no evidence (unanswerable).\n"
        } else {
            for unit in item.expected {
                out += "- Expected `\(unit.evidence.joined(separator: "+"))` (top 5: \(unit.coveredInTop5 ? "found" : "missed"); prompt: \(unit.coveredByPrompt ? "included" : "missing")): \(unit.spans.joined(separator: " OR "))\n"
            }
        }
        out += "\nSearch results (live check applied):\n\n"
        if item.search.isEmpty { out += "- none\n" }
        for hit in item.search {
            let place = "\(hit.title) (\(hit.version)) p.\(hit.page.map(String.init) ?? "?")"
            let label = hit.rank.map { "#\($0)" } ?? "dropped: \(hit.droppedBy ?? "live check")"
            out += "- \(label) — \(place)\(hit.covers.isEmpty ? "" : " — covers \(hit.covers.joined(separator: ", "))"): \(hit.excerpt)\n"
        }
        out += "\nEvidence given to the prompt:\n\n"
        if item.evidence.isEmpty { out += "- none\n" }
        for row in item.evidence {
            out += "- \(row.source) — \(row.title) (\(row.version)) p.\(row.page.map(String.init) ?? "?")\(row.covers.isEmpty ? "" : " — covers \(row.covers.joined(separator: ", "))"): \(row.excerpt)\n"
        }
        if !item.droppedByLiveCheck.isEmpty {
            out += "\nDropped by the live check (working as intended): "
            out += item.droppedByLiveCheck.map { "\($0.title) — \($0.reason)" }.joined(separator: "; ") + "\n"
        }
        return out + "\n"
    }

    private func metadataTable() -> String {
        let m = metadata
        let rows: [(String, String)] = [
            ("Corpus", "v\(m.corpusVersion) (\(m.corpusChecksum.prefix(12)))"),
            ("Code", m.commit ?? "unknown"),
            ("OS / hardware", "\(m.operatingSystem) / \(m.hardware)"),
            ("Retrieval", m.retrieval),
            ("Extraction / chunking / index schema", "\(m.extractionVersion) / \(m.chunkingVersion) / \(m.indexSchemaVersion)"),
            ("sqlite-vec", m.sqliteVecVersion),
            ("Ranker", m.ranker),
            ("Evidence limits", m.evidenceLimits),
            ("Subsets", m.subsets.joined(separator: ", "))
        ]
        return "| | |\n|---|---|\n" + rows.map { "| \($0.0) | \($0.1) |" }.joined(separator: "\n") + "\n"
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
    }
}
