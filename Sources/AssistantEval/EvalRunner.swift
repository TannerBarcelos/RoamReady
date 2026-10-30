import Foundation
import CryptoKit
import CampCore
import DocumentSearch

public enum EvalRetrieval: Sendable {
    case lexicalOnly
    /// Vector-assisted search. `label` names the provider in the report.
    case embedding(any EmbeddingProvider, label: String)
}

public struct EvalOptions: Sendable {
    public var subsets: Set<EvalCorpus.Subset> = Set(EvalCorpus.Subset.allCases)
    public var commit: String?
    /// How many passages a search returns. Hit@5, Recall@5, and the reciprocal rank are read from these.
    public var searchLimit = 8
    /// Reads passage and question language, as the app does with NaturalLanguage.
    public var languageDetector: any LanguageDetecting = NaturalLanguageDetector()
    public var generationNote = "The generated-answer suite is a manual human-rubric review and is not automated by this harness."

    public init() {}
}

/// Runs the corpus through the Assistant's retrieval path: scoped search over a throwaway index, validation
/// against the live library, then the same prompt and citation rules the Assistant uses. It measures retrieval
/// and evidence handling, not generated text.
public enum EvalRunner {
    public static let extractionVersion = 1
    static let topK = 5

    public static func run(corpus: EvalCorpus, retrieval: EvalRetrieval, options: EvalOptions = EvalOptions()) async throws -> EvalReport {
        var provider: (any EmbeddingProvider)?
        var profile: EmbeddingProfile?
        var label = "lexical-only"
        if case .embedding(let candidate, let name) = retrieval {
            guard case .available(let found) = await candidate.availability() else {
                return notRun(corpus: corpus, options: options, label: name,
                              reason: "The embedding model (\(name)) is not available on this machine, so the vector-assisted run did not happen.")
            }
            provider = candidate
            profile = found
            label = "\(name) (revision \(found.revision), dimension \(found.dimension))"
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantEval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try DocumentSearchIndex(url: directory.appendingPathComponent("eval.sqlite"))

        // Bytes that never arrived mean nothing was extracted, so those documents are not in the index.
        for doc in corpus.documents where doc.isIndexed {
            let pages = doc.pages.map { ExtractedPage(ordinal: $0.ordinal, label: $0.label, text: $0.text) }
            let record = IndexedDocument(id: uuid(doc.id).uuidString, checksum: doc.indexedChecksum, extractionVersion: extractionVersion,
                                         chunkingVersion: PassageChunker.version, language: "en")
            let admission = DocumentLanguagePolicy.admit(PassageChunker.passages(from: pages), using: options.languageDetector)
            try await index.publish(record, passages: admission.admitted, embedding: provider)
        }

        var results: [EvalReport.CaseResult] = []
        for item in corpus.cases where options.subsets.contains(item.subset) {
            results.append(try await runCase(item, corpus: corpus, index: index, provider: provider, limit: options.searchLimit,
                                          detector: options.languageDetector))
        }
        await index.close()

        let required = results.filter { $0.kind == "required" }
        let outcome: EvalReport.Outcome = required.allSatisfy(\.passed) ? .passed : .failed
        return EvalReport(
            outcome: outcome, notRunReason: nil,
            metadata: metadata(corpus: corpus, options: options, label: label, profile: profile),
            generation: .init(status: "not run", reason: options.generationNote),
            required: aggregate(required), requiredDev: aggregate(required.filter { $0.subset == "dev" }),
            requiredHeldOut: aggregate(required.filter { $0.subset == "heldout" }),
            challenge: aggregate(results.filter { $0.kind == "challenge" }), cases: results)
    }

    /// A run that could not happen. It carries no scores, and callers must treat it as neither a pass nor a fail.
    public static func notRun(corpus: EvalCorpus, options: EvalOptions = EvalOptions(), label: String, reason: String) -> EvalReport {
        EvalReport(outcome: .notRun, notRunReason: reason, metadata: metadata(corpus: corpus, options: options, label: label, profile: nil),
                   generation: .init(status: "not run", reason: options.generationNote),
                   required: .init(), requiredDev: .init(), requiredHeldOut: .init(), challenge: .init(), cases: [])
    }

    // MARK: One case

    private static func runCase(_ item: EvalCorpus.Case, corpus: EvalCorpus, index: DocumentSearchIndex,
                                provider: (any EmbeddingProvider)?, limit: Int,
                                detector: any LanguageDetecting) async throws -> EvalReport.CaseResult {
        let byUUID = Dictionary(uniqueKeysWithValues: corpus.documents.map { (uuid($0.id), $0) })
        let units = try corpus.units(for: item)

        let allowList = Set(corpus.documents.filter { doc in
            doc.isIndexed && verdict(doc, item.scope, corpus, state: (item.staleAllowList ?? false) ? .indexed : .live).inScope
        }.map { uuid($0.id).uuidString })
        // A confidently non-English question is answered with the English-only explanation, never searched.
        let needsEnglish = !allowList.isEmpty && DocumentLanguagePolicy.check(question: item.question, using: detector) == .needsEnglish
        let search = try await index.search(item.question, documentIDs: needsEnglish ? [] : allowList, limit: limit, embedding: provider)

        // The live library, as the Assistant captures it right before building the prompt.
        var live: [UUID: LiveDocument] = [:]
        for doc in corpus.documents where doc.liveStatus == .present {
            live[uuid(doc.id)] = LiveDocument(id: uuid(doc.id), title: doc.title, category: doc.category, checksum: doc.liveChecksum,
                                              isInScope: verdict(doc, item.scope, corpus, state: .live).inScope)
        }

        // Search rows, annotated with whether the live check keeps them.
        struct Row { var hit: SearchHit; var doc: EvalCorpus.Document; var droppedBy: String?; var rank: Int? }
        var rows: [Row] = []
        var rank = 0
        var dropped: [EvalReport.Violation] = []
        for hit in search.hits {
            guard let id = UUID(uuidString: hit.documentID), let doc = byUUID[id] else { continue }
            var reason: String?
            if doc.liveStatus == .deleted { reason = "document was deleted" }
            else if hit.checksum != doc.liveChecksum { reason = "the file changed since it was indexed (\(hit.checksum) is not \(doc.liveChecksum))" }
            else if case let v = verdict(doc, item.scope, corpus, state: .live), !v.inScope { reason = v.reason }
            if reason == nil { rank += 1 }
            if let reason { dropped.append(.init(document: doc.id, title: doc.title, page: hit.page, reason: reason)) }
            rows.append(Row(hit: hit, doc: doc, droppedBy: reason, rank: reason == nil ? rank : nil))
        }

        func covered(by text: String, doc: String, checksum: String, page: Int?) -> [Int] {
            units.indices.filter { u in
                units[u].spans.contains { located in
                    located.span.document == doc && checksum == "\(doc)@\(located.span.version)" && page == located.span.page
                        && EvalCorpus.normalized(text).contains(EvalCorpus.normalized(located.span.quote))
                }
            }
        }
        func unitNames(_ indices: [Int]) -> [String] { indices.flatMap { units[$0].ids } }

        let searchRows: [EvalReport.SearchResultRow] = rows.map { row in
            EvalReport.SearchResultRow(
                rank: row.rank, document: row.doc.id, title: row.doc.title, version: row.hit.checksum.components(separatedBy: "@").last ?? "",
                page: row.hit.page, excerpt: excerpt(row.hit.text), matchedLexically: row.hit.matchedLexically, matchedByVector: row.hit.matchedByVector,
                covers: row.droppedBy == nil ? unitNames(covered(by: row.hit.text, doc: row.doc.id, checksum: row.hit.checksum, page: row.hit.page)) : [],
                droppedBy: row.droppedBy)
        }
        let ranked = rows.filter { $0.rank != nil }
        let topFive = ranked.prefix(topK)
        var topCovered = Set<Int>()
        var firstRank: Int?
        for row in ranked {
            let hits = covered(by: row.hit.text, doc: row.doc.id, checksum: row.hit.checksum, page: row.hit.page)
            if !hits.isEmpty, firstRank == nil { firstRank = row.rank }
            if row.rank! <= topK { topCovered.formUnion(hits) }
        }

        // The evidence the prompt gets.
        let candidates = search.hits.compactMap { hit -> DocumentEvidenceCandidate? in
            guard let id = UUID(uuidString: hit.documentID) else { return nil }
            return DocumentEvidenceCandidate(documentID: id, indexedChecksum: hit.checksum, page: hit.page, pageLabel: hit.pageLabel,
                                             section: hit.section, text: hit.text)
        }
        var evidence = DocumentEvidence.make(question: item.question, candidates: candidates, live: live)
        // The Assistant's targeted follow-up for booking questions, among the trip's Reservation documents only.
        if item.scope.trip != nil, let query = BookingFactQuestion.followUpQuery(for: item.question) {
            let reservations = allowList.filter { id in UUID(uuidString: id).flatMap { live[$0] }?.category == "Reservation" }
            if !reservations.isEmpty {
                let followUp = try await index.search(query, documentIDs: reservations, limit: limit, embedding: provider)
                let extra = followUp.hits.compactMap { hit -> DocumentEvidenceCandidate? in
                    UUID(uuidString: hit.documentID).map {
                        DocumentEvidenceCandidate(documentID: $0, indexedChecksum: hit.checksum, page: hit.page, pageLabel: hit.pageLabel,
                                                  section: hit.section, text: hit.text)
                    }
                }
                evidence = evidence.merging(followUp: DocumentEvidence.make(question: query, candidates: extra, live: live))
            }
        }
        var promptCovered = Set<Int>()
        var evidenceRows: [EvalReport.EvidenceRow] = []
        var scopeViolations: [EvalReport.Violation] = []
        var stale: [EvalReport.Violation] = []
        var exactCodeSuccess: Bool?
        for excerpt in evidence.excerpts {
            guard let doc = byUUID[excerpt.source.documentID] else { continue }
            let cover = covered(by: excerpt.text, doc: doc.id, checksum: excerpt.source.checksum, page: excerpt.source.page)
            promptCovered.formUnion(cover)
            evidenceRows.append(.init(source: excerpt.source.id, document: doc.id, title: doc.title,
                                      version: excerpt.source.checksum.components(separatedBy: "@").last ?? "", page: excerpt.source.page,
                                      excerpt: Self.excerpt(excerpt.text), covers: unitNames(cover)))
            // Audited against the library itself, not against what `make` decided.
            let v = verdict(doc, item.scope, corpus, state: .live)
            if !v.inScope { scopeViolations.append(.init(document: doc.id, title: doc.title, page: excerpt.source.page, reason: v.reason ?? "out of scope")) }
            if doc.liveStatus != .present {
                stale.append(.init(document: doc.id, title: doc.title, page: excerpt.source.page, reason: "the document no longer exists"))
            } else if excerpt.source.checksum != doc.liveChecksum {
                stale.append(.init(document: doc.id, title: doc.title, page: excerpt.source.page,
                                   reason: "cited \(excerpt.source.checksum) but the library has \(doc.liveChecksum)"))
            }
        }
        if let code = item.exactCode, item.answerable {
            exactCodeSuccess = evidence.excerpts.contains { excerpt in
                excerpt.text.range(of: code, options: .caseInsensitive) != nil
                    && !covered(by: excerpt.text, doc: byUUID[excerpt.source.documentID]?.id ?? "", checksum: excerpt.source.checksum, page: excerpt.source.page).isEmpty
            }
        }

        // Citations and prompt handling, on the request the Assistant would build.
        let savedFacts = corpus.savedFacts(forTrip: item.scope.trip)
        let request = CampingHelpRequest(question: item.question, steps: [], rigType: nil, step: nil,
                                         scope: item.scope.trip == nil ? .general : .checklist, documents: evidence, tripFacts: savedFacts)
        let citationFailures = Self.citationFailures(evidence: evidence, byUUID: byUUID, scope: item.scope, corpus: corpus)
        let promptFailures = Self.promptFailures(item, request: request, evidence: evidence, units: units, covered: covered)
            + Self.savedFactFailures(item, request: request, savedFacts: savedFacts)

        // Metrics and explanations.
        let answerable = item.answerable
        let hit5: Bool? = answerable ? !topCovered.isEmpty : nil
        let recall: Double? = answerable ? Double(topCovered.count) / Double(units.count) : nil
        let reciprocal: Double? = answerable ? (firstRank.map { 1 / Double($0) } ?? 0) : nil
        let falsePositive = !answerable && !evidence.isEmpty

        var failures: [String] = []
        var expected: [EvalReport.ExpectedUnit] = []
        for (u, unit) in units.enumerated() {
            let spans = unit.spans.map { "\($0.span.document)@\($0.span.version) p.\($0.span.page) \"\($0.span.quote)\"" }
            expected.append(.init(evidence: unit.ids, spans: spans, coveredInTop5: topCovered.contains(u), coveredByPrompt: promptCovered.contains(u)))
            if !topCovered.contains(u) {
                failures.append("Missed evidence `\(unit.ids.joined(separator: "+"))`: \(spans.joined(separator: " OR ")). "
                    + missExplanation(unit, corpus: corpus, rows: rows.map { ($0.doc, $0.hit, $0.rank, $0.droppedBy) },
                                      allowList: allowList, scope: item.scope, limit: limit))
            } else if !promptCovered.contains(u) {
                failures.append("Evidence `\(unit.ids.joined(separator: "+"))` was in the top 5 but did not reach the prompt (removed by the relevance threshold or the excerpt cap).")
            }
        }
        if falsePositive {
            failures.append("False positive: the question has no answer in scope, but the prompt got \(evidence.excerpts.count) excerpt(s): "
                + evidenceRows.map { "\($0.title) p.\($0.page.map(String.init) ?? "?")" }.joined(separator: "; "))
        }
        for v in scopeViolations { failures.append("Scope violation: \(v.title) p.\(v.page.map(String.init) ?? "?") reached the prompt — \(v.reason).") }
        for v in stale { failures.append("Stale evidence: \(v.title) p.\(v.page.map(String.init) ?? "?") — \(v.reason).") }
        if exactCodeSuccess == false { failures.append("Exact code `\(item.exactCode ?? "")` did not appear verbatim in evidence that answers the question.") }
        failures += citationFailures.map { "Citation: \($0)" }
        failures += promptFailures.map { "Prompt: \($0)" }

        return EvalReport.CaseResult(
            id: item.id, subset: item.subset.rawValue, kind: item.kind.rawValue, tags: item.tags ?? [], pendingFeature: item.pendingFeature,
            notes: item.notes, question: item.question, scope: describe(item.scope, corpus), answerable: answerable, passed: failures.isEmpty,
            expected: expected, search: searchRows, evidence: evidenceRows, hitAt5: hit5, recallAt5: recall, reciprocalRank: reciprocal,
            unitsCovered: answerable ? topCovered.count : 0, unitsTotal: answerable ? units.count : 0, exactCode: item.exactCode,
            exactCodeSuccess: exactCodeSuccess, scopeViolations: scopeViolations, staleEvidence: stale, droppedByLiveCheck: dropped,
            noEvidenceFalsePositive: falsePositive, citationFailures: citationFailures, promptFailures: promptFailures, failures: failures)
    }

    private static func missExplanation(_ unit: EvalCorpus.EvidenceUnit, corpus: EvalCorpus,
                                        rows: [(doc: EvalCorpus.Document, hit: SearchHit, rank: Int?, droppedBy: String?)],
                                        allowList: Set<String>, scope: EvalCorpus.Scope, limit: Int) -> String {
        let documents = Set(unit.spans.map(\.span.document))
        // Retrieved, but a different passage outranked it or the live check removed it.
        for row in rows where documents.contains(row.doc.id) {
            let onPage = unit.spans.contains { $0.span.document == row.doc.id && $0.span.page == row.hit.page }
            guard onPage else { continue }
            if let reason = row.droppedBy { return "Retrieved but removed by the live check: \(reason)." }
            if let rank = row.rank { return "Retrieved at rank \(rank), outside the top \(topK)." }
        }
        for id in documents {
            guard let doc = corpus.document(id) else { continue }
            if !doc.isIndexed { return "The document is not indexed (its bytes are unavailable)." }
            if !allowList.contains(uuid(id).uuidString) {
                let v = verdict(doc, scope, corpus, state: .live)
                return "The document was outside the search scope: \(v.reason ?? "not allowed for this question")."
            }
        }
        return "In scope but not among the top \(limit) results: the page's words didn't match the question and no vector bridged them."
    }

    // MARK: Citations and prompts

    private static func citationFailures(evidence: DocumentEvidence, byUUID: [UUID: EvalCorpus.Document], scope: EvalCorpus.Scope,
                                         corpus: EvalCorpus) -> [String] {
        var failures: [String] = []
        let full = evidence.manifest(compact: false)
        let compact = evidence.manifest(compact: true)
        for source in full {
            guard let doc = byUUID[source.documentID] else { failures.append("\(source.id) names an unknown document."); continue }
            if doc.liveStatus != .present { failures.append("\(source.id) cites a deleted document, \(doc.title).") }
            else if source.checksum != doc.liveChecksum { failures.append("\(source.id) cites \(source.checksum), but the live version is \(doc.liveChecksum).") }
            if !verdict(doc, scope, corpus, state: .live).inScope { failures.append("\(source.id) cites \(doc.title), which is out of scope.") }
        }
        if Set(full.map(\.id)).count != full.count { failures.append("Source IDs are not unique.") }
        // Citing every ID in the manifest resolves them all; a forged ID resolves to nothing.
        let allIDs = full.map { "[\($0.id)]" }.joined(separator: " ")
        let resolved = DocumentCitations.resolve("Answer \(allIDs) and a forged one [S99].", manifest: full)
        if resolved.sources.count != full.count { failures.append("Valid citations did not all resolve (\(resolved.sources.count) of \(full.count)).") }
        if resolved.droppedCount != 1 { failures.append("A forged source ID was not rejected.") }
        // The compact retry keeps a subset and refuses citations to what it dropped.
        if !Set(compact.map(\.id)).isSubset(of: Set(full.map(\.id))) { failures.append("The compact manifest has an ID the full manifest lacks.") }
        let droppedIDs = full.map(\.id).filter { id in !compact.contains { $0.id == id } }
        if !droppedIDs.isEmpty {
            let retry = DocumentCitations.resolve("Answer " + droppedIDs.map { "[\($0)]" }.joined(separator: " "), manifest: compact)
            if !retry.sources.isEmpty || retry.droppedCount != droppedIDs.count {
                failures.append("The compact retry accepted a citation to a dropped passage.")
            }
        }
        return failures
    }

    private static func promptFailures(_ item: EvalCorpus.Case, request: CampingHelpRequest, evidence: DocumentEvidence,
                                       units: [EvalCorpus.EvidenceUnit],
                                       covered: (String, String, String, Int?) -> [Int]) -> [String] {
        var failures: [String] = []
        let begin = "BEGIN DOCUMENT EXCERPTS", end = "END DOCUMENT EXCERPTS"
        for (name, prompt) in [("prompt", request.prompt), ("compact prompt", request.compactPrompt)] where !evidence.isEmpty || evidence.searched {
            if prompt.components(separatedBy: begin).count != 2 || prompt.components(separatedBy: end).count != 2 {
                failures.append("The \(name) has a forged or missing excerpt delimiter.")
            }
            for marker in item.forgedMarkers ?? [] where prompt.contains(marker) {
                failures.append("The \(name) contains the forged marker \(marker) verbatim.")
            }
            let before = prompt.components(separatedBy: begin).first ?? ""
            for marker in item.injectionMarkers ?? [] where before.localizedCaseInsensitiveContains(marker) {
                failures.append("Text from a document (\"\(marker)\") appears outside the framed excerpt block in the \(name).")
            }
        }
        for marker in item.injectionMarkers ?? [] where request.instructions.localizedCaseInsensitiveContains(marker) {
            failures.append("Text from a document (\"\(marker)\") reached the model's instructions.")
        }
        if item.compactRetry == true {
            let best = evidence.excerpts.first
            let compact = EvalCorpus.normalized(request.compactPrompt)
            let keepsAnswer = units.contains { unit in unit.spans.contains { compact.contains(EvalCorpus.normalized($0.span.quote)) } }
            if best == nil { failures.append("The compact retry has no evidence to keep.") }
            else if !keepsAnswer { failures.append("The compact retry's strongest excerpt no longer contains the labeled answer.") }
            let compactIDs = evidence.manifest(compact: true).map(\.id)
            if compactIDs.count > 1 { failures.append("The compact retry kept \(compactIDs.count) passages instead of the strongest one.") }
            if evidence.manifest(compact: false).count < 2 { failures.append("The case didn't produce enough evidence to exercise the compact retry.") }
            for id in evidence.manifest(compact: false).map(\.id) where !compactIDs.contains(id) && request.compactPrompt.contains("[\(id)] ") {
                failures.append("The compact prompt still shows the dropped source \(id).")
            }
        }
        return failures
    }

    /// The saved trip's facts stay in their own block, apart from the excerpts, and are never changed by building a prompt.
    private static func savedFactFailures(_ item: EvalCorpus.Case, request: CampingHelpRequest, savedFacts: TripBookingFacts?) -> [String] {
        guard let savedFacts else { return [] }
        var failures: [String] = []
        let prompt = request.prompt
        let begin = TripBookingFacts.beginMarker, end = TripBookingFacts.endMarker
        guard prompt.components(separatedBy: begin).count == 2, prompt.components(separatedBy: end).count == 2,
              let block = prompt.components(separatedBy: begin).last?.components(separatedBy: end).first else {
            return ["The saved-facts block is missing or its delimiters are duplicated."]
        }
        let excerpts = prompt.components(separatedBy: "BEGIN DOCUMENT EXCERPTS").last ?? ""
        for value in item.savedValues ?? [] {
            if !block.contains(value) { failures.append("The saved value \"\(value)\" is missing from the saved-facts block.") }
            if excerpts.contains("saved") && excerpts.contains(value) && block.contains(value), prompt.components(separatedBy: "BEGIN DOCUMENT EXCERPTS").count == 2,
               excerpts.components(separatedBy: "END DOCUMENT EXCERPTS").first?.contains(TripBookingFacts.beginMarker) == true {
                failures.append("The saved-facts block sits inside the document excerpts.")
            }
        }
        if !request.compactPrompt.contains(begin) { failures.append("The compact prompt dropped the saved-facts block.") }
        if !request.instructions.contains("Do not choose between them") || !request.instructions.contains("Never say you checked all") {
            failures.append("The conflict rules did not reach the model's instructions.")
        }
        // Prompt building reads a value snapshot; the facts must equal themselves afterward.
        if savedFacts != corpusCopy(of: savedFacts) { failures.append("Saved trip facts changed while the request was built.") }
        return failures
    }

    private static func corpusCopy(of facts: TripBookingFacts) -> TripBookingFacts { facts }

    // MARK: Scope

    enum State { case live, indexed }

    /// Whether a document may answer a question with this scope, and if not, why. The Assistant's rule: Manual,
    /// Service & maintenance, Warranty, and Reservation are in; Registration and Insurance are out; Other is in only
    /// when opted in; unattached documents are out; a document answers for its rig, or for its trip and that trip's rig.
    static func verdict(_ doc: EvalCorpus.Document, _ scope: EvalCorpus.Scope, _ corpus: EvalCorpus, state: State) -> (inScope: Bool, reason: String?) {
        if state == .live {
            if doc.liveStatus == .deleted { return (false, "document was deleted") }
            if doc.liveStatus == .bytesUnavailable { return (false, "the file's bytes are unavailable") }
        }
        switch doc.category {
        case "Registration", "Insurance": return (false, "excluded category (\(doc.category))")
        case "Other": if doc.optedIn != true { return (false, "an Other document that is not opted in") }
        default: break
        }
        let owner = state == .indexed ? (doc.indexedOwner ?? doc.owner) : doc.owner
        if owner == "unattached" { return (false, "an unattached document") }
        let allowedRigs: Set<String>
        let allowedTrips: Set<String>
        if let trip = scope.trip, let found = corpus.trips.first(where: { $0.id == trip }) {
            allowedRigs = [found.rig]
            allowedTrips = [trip]
        } else {
            allowedRigs = scope.rig.map { [$0] } ?? []
            allowedTrips = []
        }
        if owner.hasPrefix("rig:"), allowedRigs.contains(String(owner.dropFirst(4))) { return (true, nil) }
        if owner.hasPrefix("trip:"), allowedTrips.contains(String(owner.dropFirst(5))) { return (true, nil) }
        return (false, "belongs to \(owner.replacingOccurrences(of: ":", with: " ")), not to this scope")
    }

    private static func describe(_ scope: EvalCorpus.Scope, _ corpus: EvalCorpus) -> String {
        if let trip = scope.trip { return "trip \(trip) (\(corpus.trips.first { $0.id == trip }?.name ?? "?"))" }
        return "rig \(scope.rig ?? "?") (\(corpus.rigs.first { $0.id == scope.rig }?.name ?? "?")), general"
    }

    // MARK: Aggregation

    static func aggregate(_ results: [EvalReport.CaseResult]) -> EvalReport.Aggregate {
        var a = EvalReport.Aggregate()
        a.cases = results.count
        let answerable = results.filter(\.answerable)
        a.answerable = answerable.count
        a.unanswerable = results.count - answerable.count
        a.passed = results.filter(\.passed).count
        a.failedCases = results.filter { !$0.passed }.map(\.id)
        if !answerable.isEmpty {
            a.hitAt5 = Double(answerable.filter { $0.hitAt5 == true }.count) / Double(answerable.count)
            a.recallAt5 = answerable.reduce(0.0) { $0 + ($1.recallAt5 ?? 0) } / Double(answerable.count)
            a.mrr = answerable.reduce(0.0) { $0 + ($1.reciprocalRank ?? 0) } / Double(answerable.count)
        }
        a.unitsCovered = answerable.reduce(0) { $0 + $1.unitsCovered }
        a.unitsTotal = answerable.reduce(0) { $0 + $1.unitsTotal }
        let exact = results.filter { $0.exactCodeSuccess != nil }
        a.exactCodeCases = exact.count
        a.exactCodeSuccesses = exact.filter { $0.exactCodeSuccess == true }.count
        if !exact.isEmpty { a.exactCodeSuccess = Double(a.exactCodeSuccesses) / Double(exact.count) }
        a.scopeViolations = results.reduce(0) { $0 + $1.scopeViolations.count }
        a.staleEvidence = results.reduce(0) { $0 + $1.staleEvidence.count }
        a.noEvidenceFalsePositives = results.filter(\.noEvidenceFalsePositive).count
        if a.unanswerable > 0 { a.falsePositiveRate = Double(a.noEvidenceFalsePositives) / Double(a.unanswerable) }
        a.citationInvalidCases = results.filter { !$0.citationFailures.isEmpty }.count
        if !results.isEmpty { a.citationValidity = Double(results.count - a.citationInvalidCases) / Double(results.count) }
        a.promptFailures = results.filter { !$0.promptFailures.isEmpty }.count
        return a
    }

    // MARK: Metadata

    static func metadata(corpus: EvalCorpus, options: EvalOptions, label: String, profile: EmbeddingProfile?) -> EvalReport.Metadata {
        let data = (try? JSONEncoder().encode(corpus)) ?? Data()
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return EvalReport.Metadata(
            corpusVersion: corpus.version, corpusChecksum: checksum, commit: options.commit,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, hardware: hardware(), retrieval: label,
            embeddingRevision: profile?.revision, embeddingDimension: profile?.dimension, extractionVersion: extractionVersion,
            chunkingVersion: PassageChunker.version, indexSchemaVersion: DocumentSearchIndex.schemaVersion,
            sqliteVecVersion: DocumentSearchIndex.sqliteVecVersion, ranker: "reciprocal rank fusion of FTS5 and vector results; relevance threshold \(DocumentRelevance.minimumCoverage)",
            evidenceLimits: "\(DocumentEvidence.maximumExcerpts) excerpts, \(DocumentEvidence.maximumExcerptCharacters) characters each, \(DocumentEvidence.maximumPromptCharacters) per prompt, \(DocumentEvidence.maximumCompactCharacters) in the compact retry",
            subsets: options.subsets.map(\.rawValue).sorted(), generatedAt: Date())
    }

    static func hardware() -> String {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        return [sysctl("hw.model"), sysctl("machdep.cpu.brand_string")].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Helpers

    /// A stable UUID per corpus document ID, so labels can name documents by their readable ID.
    static func uuid(_ id: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func excerpt(_ text: String) -> String {
        let flat = EvalCorpus.normalized(text)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }
}
