import Foundation
import CryptoKit
import CampCore
import DocumentSearch

/// The model the generated-answer run talks to. The command supplies Apple's on-device adapter; tests supply a stub.
@MainActor
public struct GenerationBackend {
    public enum Availability: Sendable {
        case available(details: [String: String])
        case unavailable(reason: String)
    }

    public var availability: Availability
    public var label: String
    public var model: any CampingChatModel
    public var counter: any PromptTokenCounting
    public var counterLabel: String

    public init(availability: Availability, label: String, model: any CampingChatModel,
                counter: any PromptTokenCounting = ConservativeTokenEstimator(), counterLabel: String = "conservative estimator") {
        self.availability = availability; self.label = label; self.model = model
        self.counter = counter; self.counterLabel = counterLabel
    }

    /// A model that answers each turn on its own, with no conversation.
    public init(availability: Availability, label: String, generator: any CampingResponseGenerating,
                counter: any PromptTokenCounting = ConservativeTokenEstimator(), counterLabel: String = "conservative estimator") {
        self.init(availability: availability, label: label, model: SingleTurnChatModel(generator), counter: counter, counterLabel: counterLabel)
    }
}

public struct GenerationEvalOptions: Sendable {
    public var samples = 3
    public var commit: String?
    public var searchLimit = 8
    public var languageDetector: any LanguageDetecting = NaturalLanguageDetector()
    /// Run only these scenarios when set.
    public var scenarioIDs: Set<String>?

    public init() {}
}

/// The review sheet for generated answers. Nothing in it is scored: the rubric fields are empty for a person to
/// fill in. A run that could not happen has the status "not run" and no scenarios, and is never a pass.
public struct GenerationReview: Codable, Equatable, Sendable {
    public struct Rubric: Codable, Equatable, Sendable {
        /// Each of these is "pass", "fail", or "n/a" once a reviewer has judged it.
        public var supportedFacts: String?
        public var correctAttribution: String?
        public var noInventedSpecsOrBookingDetails: String?
        public var appropriateMissingEvidenceResponse: String?
        public var safetyPreserved: String?
        public var verdict: String?
        public var notes = ""
        public init() {}
    }

    public struct Citation: Codable, Equatable, Sendable {
        public var id: String
        public var document: String
        public var title: String
        public var page: Int?
    }

    public struct Answer: Codable, Equatable, Sendable {
        public var sample: Int
        /// "answered", or "failed" with the failure named.
        public var status: String
        public var failure: String?
        /// The model's reply exactly as returned, citation markers included.
        public var rawText: String
        /// What the camper would read: markers removed.
        public var shownText: String
        /// Citations that resolved to the manifest of the prompt actually used.
        public var validatedCitations: [Citation]
        /// Cited IDs that were not in that manifest and were dropped.
        public var rejectedCitationIDs: Int
        public var coverage: String
        public var usedSavedTrip: Bool
        public var usedCompactRetry: Bool
        public var seconds: Double
        /// The full prompt this sample received (synthetic data only).
        public var prompt: String
        public var rubric = Rubric()
    }

    public struct Supplied: Codable, Equatable, Sendable {
        public var sourceID: String
        public var document: String
        public var title: String
        public var version: String
        public var page: Int?
        /// The excerpt text that went into the prompt, bounded as the prompt bounds it.
        public var text: String
    }

    public struct Turn: Codable, Equatable, Sendable {
        public var label: String
        public var question: String
        public var scope: String
        public var corpusCase: String?
        public var lookFor: [String]
        /// Labeled evidence for the question, from the retrieval corpus, when the turn reuses one of its cases.
        public var expectedEvidence: [String]
        /// A fixed English-only explanation was shown instead of calling the model.
        public var englishOnlyNotice: String?
        public var savedTripFactsSupplied: Bool
        public var readiness: String?
        public var supplied: [Supplied]
        /// Deterministic audit of what was supplied, against the library for this turn.
        public var crossScopeOrExcludedSources: [EvalReport.Violation]
        public var staleSources: [EvalReport.Violation]
        public var answers: [Answer]
    }

    public struct Scenario: Codable, Equatable, Sendable {
        public var id: String
        public var group: String
        public var kind: String
        public var purpose: String
        public var turns: [Turn]
    }

    public struct Config: Codable, Equatable, Sendable {
        public var samplesPerScenario: Int
        public var model: String
        public var modelDetails: [String: String]
        public var maximumResponseTokens: Int
        public var tokenCounter: String
        /// "Fresh session per call, bounded recent turns; sampling options left at the framework default."
        public var sessionPolicy: String
        public var promptVersion: String
        public var evidenceLimits: String
    }

    public var status: String
    public var notRunReason: String?
    public var metadata: EvalReport.Metadata
    public var generation: Config
    public var scenarios: [Scenario]

    public static let ready = "ready for review"
    public static let notRun = "not run"

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Runs the review scenarios through the real generation path: scoped retrieval over a throwaway index, live
/// validation, `CampingHelpRequest`, and `CampingGeneration.answer`. It makes no judgment about the answers.
@MainActor
public enum GenerationEvalRunner {
    public static func run(corpus: EvalCorpus, retrieval: EvalRetrieval, backend: GenerationBackend,
                           options: GenerationEvalOptions = GenerationEvalOptions()) async throws -> GenerationReview {
        var evalOptions = EvalOptions()
        evalOptions.commit = options.commit
        evalOptions.languageDetector = options.languageDetector
        evalOptions.searchLimit = options.searchLimit

        var provider: (any EmbeddingProvider)?
        var profile: EmbeddingProfile?
        var label = "lexical-only"
        if case .embedding(let candidate, let name) = retrieval, case .available(let found) = await candidate.availability() {
            provider = candidate; profile = found
            label = "\(name) (revision \(found.revision), dimension \(found.dimension))"
        }
        let metadata = EvalRunner.metadata(corpus: corpus, options: evalOptions, label: label, profile: profile)
        let limits = metadata.evidenceLimits
        func emptyConfig(_ model: String) -> GenerationReview.Config {
            .init(samplesPerScenario: options.samples, model: model, modelDetails: [:], maximumResponseTokens: PromptBudget.outputTokens,
                  tokenCounter: backend.counterLabel, sessionPolicy: Self.sessionPolicy, promptVersion: "unknown (not run)", evidenceLimits: limits)
        }
        let details: [String: String]
        switch backend.availability {
        case .available(let found): details = found
        case .unavailable(let reason):
            return GenerationReview(status: GenerationReview.notRun, notRunReason: reason, metadata: metadata,
                                    generation: emptyConfig(backend.label), scenarios: [])
        }

        var scenarios = try GenerationScenarios.all(corpus: corpus)
        if let ids = options.scenarioIDs { scenarios = scenarios.filter { ids.contains($0.id) } }
        var instructionSet = Set<String>()
        var sheets: [GenerationReview.Scenario] = []
        for scenario in scenarios {
            sheets.append(try await runScenario(scenario, corpus: corpus, provider: provider, backend: backend, options: options,
                                                instructions: &instructionSet))
        }
        let fingerprint = Self.fingerprint(instructionSet.sorted().joined(separator: "\n----\n"))
        var config = emptyConfig(backend.label)
        config.modelDetails = details
        config.promptVersion = "instructions-sha256:\(fingerprint) (\(instructionSet.count) distinct instruction sets); prompt layout in CampCore CampingHelpRequest"
        return GenerationReview(status: GenerationReview.ready, notRunReason: nil, metadata: metadata, generation: config, scenarios: sheets)
    }

    static let sessionPolicy = "One model session per conversation (CampingChat); per-turn instructions and prompt; the session sends up to the last 3 turns that fit the budget; on context overflow, a new session keeping the newest turn and one compact retry; sampling options left at the framework default."

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: One scenario

    private struct Prepared {
        var corpus: EvalCorpus
        var evidence: DocumentEvidence
        var savedFacts: TripBookingFacts?
        var notice: Bool
        var sheet: GenerationReview.Turn
    }

    private static func runScenario(_ scenario: GenerationScenario, corpus base: EvalCorpus, provider: (any EmbeddingProvider)?,
                                    backend: GenerationBackend, options: GenerationEvalOptions,
                                    instructions: inout Set<String>) async throws -> GenerationReview.Scenario {
        // Retrieval and validation are deterministic for a turn, so they run once and every sample reuses them.
        var prepared: [Prepared] = []
        for turn in scenario.turns {
            prepared.append(try await prepare(turn, base: base, provider: provider, options: options))
        }

        // Samples run as separate conversations, so a later turn's history is that sample's own earlier answer.
        for sample in 1...max(1, options.samples) {
            let recorder = RecordingModel(backend.model)
            let chat = CampingChat(model: recorder, counter: backend.counter)
            for (index, turn) in scenario.turns.enumerated() {
                let item = prepared[index]
                guard !item.notice else { continue }
                let request = CampingHelpRequest(question: turn.question, steps: [], rigType: nil, step: nil,
                                                 scope: turn.scope.trip == nil ? .general : .checklist,
                                                 previousQuestion: chat.previousQuestion(),
                                                 documents: item.evidence, tripFacts: item.savedFacts)
                instructions.insert(request.instructions)
                recorder.startTurn()
                let started = ContinuousClock.now
                var answer: GenerationReview.Answer
                do {
                    let reply = try await chat.answer(request)
                    let seconds = Self.seconds(started.duration(to: .now))
                    answer = .init(sample: sample, status: "answered", failure: nil, rawText: recorder.lastResponse ?? reply.text,
                                   shownText: reply.text,
                                   validatedCitations: reply.sources.map { .init(id: $0.id, document: Self.documentName($0.documentID, corpus: item.corpus), title: $0.title, page: $0.page) },
                                   rejectedCitationIDs: reply.droppedCitationCount, coverage: Self.name(reply.coverage),
                                   usedSavedTrip: reply.usedSavedTrip, usedCompactRetry: recorder.calls > 1, seconds: seconds, prompt: recorder.lastPrompt ?? request.prompt)
                } catch {
                    let seconds = Self.seconds(started.duration(to: .now))
                    answer = .init(sample: sample, status: "failed", failure: String(describing: error), rawText: recorder.lastResponse ?? "",
                                   shownText: "", validatedCitations: [], rejectedCitationIDs: 0, coverage: "none",
                                   usedSavedTrip: false, usedCompactRetry: recorder.calls > 1, seconds: seconds, prompt: recorder.lastPrompt ?? request.prompt)
                }
                prepared[index].sheet.answers.append(answer)
            }
        }
        return .init(id: scenario.id, group: scenario.group.rawValue, kind: scenario.kind.rawValue, purpose: scenario.purpose,
                     turns: prepared.map(\.sheet))
    }

    private static func prepare(_ turn: GenerationScenario.Turn, base: EvalCorpus, provider: (any EmbeddingProvider)?,
                                options: GenerationEvalOptions) async throws -> Prepared {
        let corpus = turn.change?(base) ?? base
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantGeneration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try DocumentSearchIndex(url: directory.appendingPathComponent("eval.sqlite"))
        for doc in corpus.documents where doc.isIndexed {
            let pages = doc.pages.map { ExtractedPage(ordinal: $0.ordinal, label: $0.label, text: $0.text) }
            let record = IndexedDocument(id: EvalRunner.uuid(doc.id).uuidString, checksum: doc.indexedChecksum,
                                         extractionVersion: EvalRunner.extractionVersion, chunkingVersion: PassageChunker.version, language: "en")
            let admission = DocumentLanguagePolicy.admit(PassageChunker.passages(from: pages), using: options.languageDetector)
            try await index.publish(record, passages: admission.admitted, embedding: provider)
        }
        defer { Task { await index.close() } }

        let byUUID = Dictionary(uniqueKeysWithValues: corpus.documents.map { (EvalRunner.uuid($0.id), $0) })
        let scope = turn.scope
        let allowList = Set(corpus.documents.filter { $0.isIndexed && EvalRunner.verdict($0, scope, corpus, state: .live).inScope }
            .map { EvalRunner.uuid($0.id).uuidString })
        let needsEnglish = !allowList.isEmpty && DocumentLanguagePolicy.check(question: turn.question, using: options.languageDetector) == .needsEnglish

        var live: [UUID: LiveDocument] = [:]
        for doc in corpus.documents where doc.liveStatus == .present {
            live[EvalRunner.uuid(doc.id)] = LiveDocument(id: EvalRunner.uuid(doc.id), title: doc.title, category: doc.category, checksum: doc.liveChecksum,
                                                         isInScope: EvalRunner.verdict(doc, scope, corpus, state: .live).inScope)
        }

        // Every document the scope holds and how ready it is: a scan whose bytes have not arrived is waiting.
        let scoped: [ScopedDocument] = corpus.documents.compactMap { doc in
            guard doc.liveStatus != .deleted else { return nil }
            var probe = doc; probe.status = nil
            guard EvalRunner.verdict(probe, scope, corpus, state: .live).inScope else { return nil }
            return ScopedDocument(id: EvalRunner.uuid(doc.id), title: doc.title, waitingForDownload: doc.liveStatus == .bytesUnavailable)
        }
        let states = Dictionary(uniqueKeysWithValues: scoped.filter { !$0.waitingForDownload }.map { ($0.id, AssistantDocumentStatus.ready) })
        let readiness = ScopeReadiness.make(documents: scoped, states: states)

        var evidence = DocumentEvidence(excerpts: [], searched: false)
        if !needsEnglish, !allowList.isEmpty {
            let search = try await index.search(turn.question, documentIDs: allowList, limit: options.searchLimit, embedding: provider)
            evidence = DocumentEvidence.make(question: turn.question, candidates: candidates(search), live: live)
            if scope.trip != nil, let query = BookingFactQuestion.followUpQuery(for: turn.question) {
                let reservations = allowList.filter { id in UUID(uuidString: id).flatMap { live[$0] }?.category == "Reservation" }
                if !reservations.isEmpty {
                    let followUp = try await index.search(query, documentIDs: reservations, limit: options.searchLimit, embedding: provider)
                    evidence = evidence.merging(followUp: DocumentEvidence.make(question: query, candidates: candidates(followUp), live: live))
                }
            }
        }
        evidence = evidence.capturing(readiness)
        let savedFacts = corpus.savedFacts(forTrip: scope.trip)

        // The excerpts that went into the prompt, and an audit of them against this turn's library.
        let manifest = Set(evidence.manifest(compact: false).map(\.id))
        var supplied: [GenerationReview.Supplied] = []
        var crossScope: [EvalReport.Violation] = [], stale: [EvalReport.Violation] = []
        for excerpt in evidence.excerpts where manifest.contains(excerpt.source.id) {
            guard let doc = byUUID[excerpt.source.documentID] else { continue }
            supplied.append(.init(sourceID: excerpt.source.id, document: doc.id, title: doc.title,
                                  version: excerpt.source.checksum.components(separatedBy: "@").last ?? "", page: excerpt.source.page,
                                  text: String(excerpt.text.prefix(DocumentEvidence.maximumExcerptCharacters))))
            let verdict = EvalRunner.verdict(doc, scope, corpus, state: .live)
            if !verdict.inScope { crossScope.append(.init(document: doc.id, title: doc.title, page: excerpt.source.page, reason: verdict.reason ?? "out of scope")) }
            if doc.liveStatus != .present { stale.append(.init(document: doc.id, title: doc.title, page: excerpt.source.page, reason: "the document no longer exists")) }
            else if excerpt.source.checksum != doc.liveChecksum {
                stale.append(.init(document: doc.id, title: doc.title, page: excerpt.source.page, reason: "cited \(excerpt.source.checksum), library has \(doc.liveChecksum)"))
            }
        }

        let expected: [String] = (base.cases.first { $0.id == turn.corpusCase }?.evidence ?? []).flatMap { group in
            group.anyOf.map { "\(group.id): \($0.document)@\($0.version) p.\($0.page) \"\($0.quote)\"" }
        }
        let tripName = scope.trip.flatMap { id in corpus.trips.first { $0.id == id }?.name }
        let scopeText = scope.trip.map { "trip \($0) (\(tripName ?? "?"))" } ?? "rig \(scope.rig ?? "?") (\(corpus.rigs.first { $0.id == scope.rig }?.name ?? "?")), general"
        let sheet = GenerationReview.Turn(
            label: turn.label, question: turn.question, scope: scopeText, corpusCase: turn.corpusCase, lookFor: turn.lookFor,
            expectedEvidence: expected, englishOnlyNotice: needsEnglish ? DocumentLanguagePolicy.englishOnlyExplanation : nil,
            savedTripFactsSupplied: savedFacts != nil, readiness: readiness.summary, supplied: supplied,
            crossScopeOrExcludedSources: crossScope, staleSources: stale, answers: [])
        return Prepared(corpus: corpus, evidence: evidence, savedFacts: savedFacts, notice: needsEnglish, sheet: sheet)
    }

    private static func candidates(_ result: SearchResult) -> [DocumentEvidenceCandidate] {
        result.hits.compactMap { hit in
            UUID(uuidString: hit.documentID).map {
                DocumentEvidenceCandidate(documentID: $0, indexedChecksum: hit.checksum, page: hit.page, pageLabel: hit.pageLabel,
                                          section: hit.section, text: hit.text, ocrConfidence: hit.ocrConfidence)
            }
        }
    }

    private static func documentName(_ id: UUID, corpus: EvalCorpus) -> String {
        corpus.documents.first { EvalRunner.uuid($0.id) == id }?.id ?? id.uuidString
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func name(_ coverage: DocumentCoverage) -> String {
        switch coverage {
        case .notSearched: "not searched"
        case .notCovered: "not covered"
        case .uncited: "uncited"
        case .cited: "cited"
        case .unfinished: "unfinished"
        }
    }
}

/// Wraps the real model to keep exactly what each turn sent and got back, and whether the compact retry ran.
@MainActor
private final class RecordingModel: CampingChatModel {
    let inner: any CampingChatModel
    var lastPrompt: String?
    var lastResponse: String?
    var calls = 0

    init(_ inner: any CampingChatModel) { self.inner = inner }

    func startTurn() { lastPrompt = nil; lastResponse = nil; calls = 0 }

    func makeSession(history: [CampingChatTurn]) -> any CampingChatSession {
        Session(inner: inner.makeSession(history: history), recorder: self)
    }

    func summarize(_ turns: [CampingChatTurn], into summary: String?) async throws -> String {
        try await inner.summarize(turns, into: summary)
    }

    private final class Session: CampingChatSession {
        let inner: any CampingChatSession
        unowned let recorder: RecordingModel
        init(inner: any CampingChatSession, recorder: RecordingModel) { self.inner = inner; self.recorder = recorder }

        func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String {
            recorder.calls += 1
            recorder.lastPrompt = prompt
            let response = try await inner.respond(to: prompt, instructions: instructions, history: history)
            recorder.lastResponse = response
            return response
        }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                     tools: CampingTools?) async throws -> CampingSessionReply {
            recorder.calls += 1
            recorder.lastPrompt = prompt
            let reply = try await inner.respond(to: prompt, instructions: instructions, history: history, tools: tools)
            recorder.lastResponse = reply.text
            return reply
        }
        func store(_ turn: CampingChatTurn) { inner.store(turn) }
        func remove(_ turnID: CampingChatTurn.ID) { inner.remove(turnID) }
        func prewarm() { inner.prewarm() }
    }
}
