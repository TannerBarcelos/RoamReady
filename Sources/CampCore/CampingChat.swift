import Foundation

/// One finished exchange as a chat's model session stores it: the question and the answer shown, clipped,
/// with citation markers neutralized. This turn's excerpts, checklist context, and trip facts are never part
/// of it, so evidence is always fresh and earlier answers can't pass for sources.
public struct CampingChatTurn: Equatable, Identifiable, Sendable {
    public static let questionCharacters = 400
    public static let answerCharacters = 1000

    public let id: String
    public let question: String
    public let answer: String

    public init(id: String = UUID().uuidString, question: String, answer: String) {
        self.id = id
        self.question = String(question.prefix(Self.questionCharacters))
        self.answer = DocumentEvidence.neutralized(String(answer.prefix(Self.answerCharacters)))
    }
}

/// A chat's model session. Its transcript carries the conversation, so each call sends only this turn's
/// instructions and prompt. The app supplies Apple's on-device session; tests supply fakes.
@MainActor
public protocol CampingChatSession: AnyObject {
    /// Answers one turn. `instructions` and `prompt` are this turn's context and are never kept as history.
    /// `history` is the stored turns this request may send, oldest first; every other stored turn stays out.
    /// A failed or cancelled request leaves the transcript as it was.
    func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String
    /// Answers one turn with `toolTurn`'s tools available to the model, which must call at least one before
    /// answering. Its `resultsOf` names the one stored turn whose tool results this request may send with it,
    /// and its allowance bounds what results may add. Nil offers no tools.
    func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                 toolTurn: CampingToolTurn?) async throws -> CampingSessionReply
    /// Replaces the turn just answered with its stored form. The newest turn keeps its tool calls and results;
    /// every older turn is its question and answer alone.
    func store(_ turn: CampingChatTurn)
    /// Removes a stored turn, for an answer that was never shown or that compaction dropped.
    func remove(_ turnID: CampingChatTurn.ID)
    /// Loads the model ahead of a request, so the first answer starts sooner (TN3193).
    func prewarm()
}

extension CampingChatSession {
    public func prewarm() {}

    /// Sessions without tool calling answer without the tools.
    public func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                        toolTurn: CampingToolTurn?) async throws -> CampingSessionReply {
        CampingSessionReply(text: try await respond(to: prompt, instructions: instructions, history: history))
    }
}

@MainActor
public protocol CampingChatModel {
    /// A new session whose transcript starts with `history`.
    func makeSession(history: [CampingChatTurn]) -> any CampingChatSession
    /// Folds `turns` into `summary` in a new, short-lived session of its own, so the chat's session is never
    /// used for it. Returns the model's raw summary; `ConversationSummary.cleaned` bounds it.
    func summarize(_ turns: [CampingChatTurn], into summary: String?) async throws -> String
}

/// Sends every turn on its own with no history: single questions, the performance baseline, and fixtures.
public struct SingleTurnChatModel: CampingChatModel {
    private let generator: any CampingResponseGenerating

    public init(_ generator: any CampingResponseGenerating) { self.generator = generator }

    public func makeSession(history: [CampingChatTurn]) -> any CampingChatSession { Session(generator: generator) }

    public func summarize(_ turns: [CampingChatTurn], into summary: String?) async throws -> String {
        try await generator.respond(to: ConversationSummary.prompt(folding: turns, into: summary),
                                    instructions: ConversationSummary.instructions)
    }

    private final class Session: CampingChatSession {
        let generator: any CampingResponseGenerating
        init(generator: any CampingResponseGenerating) { self.generator = generator }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String {
            try await generator.respond(to: prompt, instructions: instructions)
        }
        func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                     toolTurn: CampingToolTurn?) async throws -> CampingSessionReply {
            try await generator.respond(to: prompt, instructions: instructions, tools: toolTurn?.tools)
        }
        func store(_ turn: CampingChatTurn) {}
        func remove(_ turnID: CampingChatTurn.ID) {}
    }
}

/// Which earlier turns a request sends, and what a session keeps when the context overflows.
public enum CampingChatHistory {
    /// The most earlier turns one request sends.
    public static let maximumTurns = 3
    /// The most turns a session keeps, so a long chat's transcript stays bounded. Older ones are only on screen.
    public static let storedTurns = 12
    /// Turns a session keeps after compaction: the newest, so a follow-up still has what it follows.
    public static let compactedTurns = 1
    /// Chat-template framing for one stored turn, on top of its question and answer.
    public static let turnOverheadTokens = 16

    /// The newest turns before `turnID` (all of them when nil) that fit `budget`, oldest first. It stops at the
    /// first turn that doesn't fit, so what's sent is always the most recent stretch of the conversation. A
    /// `turnID` no longer stored means every stored turn came after it, so nothing is sent.
    public static func window(_ turns: [CampingChatTurn], before turnID: CampingChatTurn.ID? = nil, budget: Int,
                              limit: Int = maximumTurns, cost: (CampingChatTurn) -> Int) -> [CampingChatTurn] {
        let earlier = earlier(turns, before: turnID)
        var kept: [CampingChatTurn] = []
        var used = 0
        for turn in earlier.reversed() {
            guard kept.count < limit else { break }
            let tokens = cost(turn)
            guard used + tokens <= budget else { break }
            used += tokens
            kept.insert(turn, at: 0)
        }
        return kept
    }

    static func earlier(_ turns: [CampingChatTurn], before turnID: CampingChatTurn.ID?) -> ArraySlice<CampingChatTurn> {
        guard let turnID else { return turns[...] }
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return [] }
        return turns[..<index]
    }

    /// What a transcript entry is, as far as trimming cares.
    public enum EntryKind: Equatable, Sendable {
        case instructions
        case prompt(id: String)
        case response
        /// A tool call or its result.
        case tool
        case other
    }

    /// The entries one request sends: the instructions, the turns in `kept`, and the current prompt (the last
    /// prompt with no response yet). A stored turn's response and anything else between prompts goes with it,
    /// except tool calls and results: those go only with the current turn and the stored turn `resultsOf`.
    /// Used by the session's history transform, so the stored transcript itself is untouched.
    public static func sent<Entry>(_ entries: [Entry], keeping kept: Set<String>, resultsOf: String? = nil,
                                   kind: (Entry) -> EntryKind) -> [Entry] {
        let kinds = entries.map(kind)
        let currentPrompt = kinds.lastIndex { if case .prompt = $0 { true } else { false } }
            .flatMap { index in kinds[(index + 1)...].contains(.response) ? nil : index }
        var result: [Entry] = []
        var keepingTurn = true
        var keepingTools = true
        for (index, entry) in entries.enumerated() {
            switch kinds[index] {
            case .instructions:
                result.append(entry)
            case .prompt(let id):
                keepingTurn = index == currentPrompt || kept.contains(id)
                keepingTools = index == currentPrompt || id == resultsOf
                if keepingTurn { result.append(entry) }
            case .tool:
                if keepingTurn && keepingTools { result.append(entry) }
            case .response, .other:
                if keepingTurn { result.append(entry) }
            }
        }
        return result
    }
}

/// One conversation with the on-device model: a model session per chat whose transcript holds the history,
/// with this turn's context planned against the token budget first and earlier turns given what's left.
/// New chat, trip and checklist help, and a change of rig or trip each start a new session.
///
/// Context follows Apple's guidance for the 4,096-token window. After an answer, once the chat holds more than
/// `ConversationSummary.compactAfterTurns`, the turns older than those a request sends are summarized and
/// dropped from the session (WWDC26: compact at a response boundary; the summary rides in the instructions).
/// If the context still overflows, everything but the newest turn is folded into the summary and the chat moves
/// to a new, prewarmed session seeded with the newest turn, then retries once (TN3193).
@MainActor
public final class CampingChat {
    public private(set) var turns: [CampingChatTurn] = []
    /// Earlier turns folded out of the session. Always older than every stored turn.
    public private(set) var summary: String?
    /// How many times this chat has compacted after an overflow, for tests and diagnostics.
    public private(set) var compactions = 0
    /// Compaction after the last answer, which the next question waits for.
    private var maintenance: Task<Void, Never>?
    /// Bumped by every reset, so compaction that started before it can't touch the new conversation.
    private var generation = 0
    private var costs: [CampingChatTurn.ID: Int] = [:]
    /// The newest turn's tool results: which turn, the snapshots they came from, and their token cost. A follow-up
    /// sends them with that turn while the snapshots are unchanged, so "What goes in it?" needn't look up again.
    private var results: (turn: CampingChatTurn.ID, tools: CampingTools, tokens: Int)?
    private var session: (any CampingChatSession)?
    private var scope: AnyHashable?
    private let model: any CampingChatModel
    private let counter: any PromptTokenCounting
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(model: any CampingChatModel, counter: any PromptTokenCounting = ConservativeTokenEstimator()) {
        self.model = model
        self.counter = counter
    }

    /// New chat: the next question starts a new session.
    public func reset() {
        turns = []
        costs = [:]
        results = nil
        session = nil
        scope = nil
        summary = nil
        generation += 1
    }

    /// Loads the model before the first question, for example when the chat opens (TN3193). Safe to repeat.
    public func prewarm() {
        currentSession().prewarm()
    }

    /// Waits for compaction started after the last answer. For tests.
    public func settle() async {
        await maintenance?.value
    }

    /// The question before this one in `scope`, which follow-ups are searched together with. Nil in a new scope.
    public func previousQuestion(in scope: AnyHashable? = nil, before turnID: CampingChatTurn.ID? = nil) -> String? {
        guard scope == self.scope else { return nil }
        return CampingChatHistory.earlier(turns, before: turnID).last?.question
    }

    /// Answers `request` as the next turn. `before` asks again as of an earlier turn: only the turns before it
    /// are sent. A different `scope` drops the conversation first, so one rig's or trip's turns never reach
    /// another's request.
    public func answer(_ request: CampingHelpRequest, in scope: AnyHashable? = nil,
                       before turnID: CampingChatTurn.ID? = nil) async throws -> CampingReply {
        try Task.checkCancellation()
        guard !request.questionExceedsLimit else { throw CampingChatFailure.contextTooLong }
        await maintenance?.value
        // A cancelled request may still be unwinding in the session; never send two at once.
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if scope != self.scope {
            reset()
            self.scope = scope
        }
        var request = request
        request.conversationSummary = request.isTripOverview ? nil : summary(before: turnID)
        let budget = PromptBudget(contextSize: counter.contextSize)
        var plan = try await request.plan(.full, counter: counter, budget: budget)
        // Room for one tool result comes out of what earlier turns may use, never out of this turn's context.
        let toolReserve = request.tools?.outputReserveTokens ?? 0
        var history: [CampingChatTurn] = []
        var resultsOf: CampingChatTurn.ID? = nil
        if !request.isTripOverview {
            (history, resultsOf) = window(before: turnID, budget: budget.inputLimit - plan.usage.total - toolReserve, tools: request.tools)
        }
        let sessionReply: CampingSessionReply
        do {
            sessionReply = try await currentSession().respond(to: plan.prompt, instructions: plan.instructions, history: history,
                                                              toolTurn: toolTurn(request, plan, history, resultsOf, budget))
        } catch CampingChatFailure.contextTooLong {
            try Task.checkCancellation()
            // The counts said the first attempt fit, so the retry must send strictly less: a smaller prompt, or
            // at least one turn fewer. Compaction starts a new session, which drops the kept tool results too.
            let promptShrank = request.compactPrompt(limitedBy: plan) != plan.prompt
            guard promptShrank || !history.isEmpty || resultsOf != nil else { throw CampingChatFailure.contextTooLong }
            let limit = min(CampingChatHistory.compactedTurns, promptShrank ? history.count : history.count - 1)
            let earlier = Set(CampingChatHistory.earlier(turns, before: turnID).map(\.id))
            await compact()
            try Task.checkCancellation()
            request.conversationSummary = request.isTripOverview ? nil : summary(before: turnID)
            plan = try await request.plan(.compact, limitedBy: plan, counter: counter, budget: budget)
            history = request.isTripOverview ? [] : CampingChatHistory.window(turns.filter { earlier.contains($0.id) }, budget: budget.inputLimit - plan.usage.total - toolReserve,
                                                limit: limit, cost: cost)
            sessionReply = try await currentSession().respond(to: plan.prompt, instructions: plan.instructions, history: history,
                                                              toolTurn: toolTurn(request, plan, history, nil, budget))
        }
        let text = sessionReply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var reply = Self.reply(text, to: request, sent: plan)
        // Looking up the trip or its menu makes the saved trip a source; the rig isn't the trip.
        if sessionReply.toolsUsed.contains(where: \.isTripData) { reply.usedSavedTrip = true }
        // The session holds the raw turn now. Store its clean form at once, so the transcript and `turns` agree.
        let turn = CampingChatTurn(question: request.question, answer: reply.text)
        currentSession().store(turn)
        turns.append(turn)
        costs[turn.id] = Self.estimate(turn)
        reply.turnID = turn.id
        guard !text.isEmpty else {
            forget(turn.id)
            throw CampingChatFailure.failed
        }
        if Task.isCancelled {
            forget(turn.id)
            throw CancellationError()
        }
        var measurer = Measurer(counter: counter)
        if let question = try? await measurer.count(turn.question), let answer = try? await measurer.count(turn.answer) {
            costs[turn.id] = question + answer + CampingChatHistory.turnOverheadTokens
        }
        if Task.isCancelled {
            forget(turn.id)
            throw CancellationError()
        }
        // Storing the turn dropped the previous turn's results from the session; this turn's take their place.
        results = nil
        if let tools = request.tools, !sessionReply.toolOutputs.isEmpty {
            let text = sessionReply.toolOutputs.joined(separator: "\n")
            let tokens = (try? await measurer.count(text)) ?? ConservativeTokenEstimator.estimate(text)
            results = (turn.id, tools, tokens + sessionReply.toolOutputs.count * Self.toolCallOverheadTokens)
        }
        // A backstop for when summaries keep failing; normally compaction keeps the chat far below this.
        while turns.count > CampingChatHistory.storedTurns { forget(turns[0].id) }
        scheduleCompaction()
        return reply
    }

    /// Drops a turn whose answer was never shown, so it can't color later answers.
    public func forget(_ turnID: CampingChatTurn.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns.remove(at: index)
        costs[turnID] = nil
        if results?.turn == turnID { results = nil }
        session?.remove(turnID)
    }

    /// A tool call's arguments and framing, on top of its result.
    static let toolCallOverheadTokens = 30

    /// The request's tools with the room their results may take: whatever the prompt and the sent history leave.
    /// It's at least one full result, since the history window kept that free.
    private func toolTurn(_ request: CampingHelpRequest, _ plan: PromptPlan, _ history: [CampingChatTurn],
                          _ resultsOf: CampingChatTurn.ID?, _ budget: PromptBudget) -> CampingToolTurn? {
        guard let tools = request.tools else { return nil }
        let sent = history.reduce(0) { $0 + cost($1) } + (resultsOf != nil ? results?.tokens ?? 0 : 0)
        return CampingToolTurn(tools: tools, resultsOf: resultsOf,
                               allowance: CampingToolAllowance(tokens: budget.inputLimit - plan.usage.total - sent))
    }

    /// The earlier turns a request sends, and whether the newest one's tool results go with it. They go only
    /// when that turn is the newest sent, this request offers the same snapshots (nothing was edited and the day
    /// hasn't changed), and the turn still fits with them; otherwise the turn goes alone.
    private func window(before turnID: CampingChatTurn.ID?, budget: Int,
                        tools: CampingTools?) -> (turns: [CampingChatTurn], resultsOf: CampingChatTurn.ID?) {
        let plain = CampingChatHistory.window(turns, before: turnID, budget: budget, cost: cost)
        guard let results, results.tools == tools, plain.last?.id == results.turn,
              CampingChatHistory.earlier(turns, before: turnID).last?.id == results.turn else { return (plain, nil) }
        let withResults = CampingChatHistory.window(turns, before: turnID, budget: budget) { turn in
            self.cost(turn) + (turn.id == results.turn ? results.tokens : 0)
        }
        return withResults.last?.id == results.turn ? (withResults, results.turn) : (plain, nil)
    }

    /// The summary a request may carry: none when asking again as of a turn no longer stored, since the summary
    /// could then cover turns after it.
    private func summary(before turnID: CampingChatTurn.ID?) -> String? {
        guard let turnID else { return summary }
        return turns.contains { $0.id == turnID } ? summary : nil
    }

    /// Apple's recovery from a full context (TN3193): summarize the old session, and start a new one from the
    /// summary and its key entry, the newest turn. The new session is prewarmed before the retry.
    private func compact() async {
        let kept = Array(turns.suffix(CampingChatHistory.compactedTurns))
        let dropped = turns.filter { turn in !kept.contains { $0.id == turn.id } }
        if let folded = await folded(dropped, into: summary) { summary = folded }
        turns = kept
        costs = costs.filter { id, _ in kept.contains { $0.id == id } }
        // A new session starts from stored questions and answers only.
        results = nil
        let made = model.makeSession(history: kept)
        made.prewarm()
        session = made
        compactions += 1
    }

    /// At a response boundary (WWDC26), folds every turn older than those a request sends into the summary and
    /// drops them from the session. It runs after the answer is shown, so the camper never waits on it; the
    /// next question waits only if it's still running.
    private func scheduleCompaction() {
        guard turns.count > ConversationSummary.compactAfterTurns else { return }
        let expected = generation
        maintenance = Task { [weak self] in await self?.compactOlderTurns(expected) }
    }

    private func compactOlderTurns(_ expected: Int) async {
        await acquire()
        defer { release() }
        guard generation == expected, turns.count > ConversationSummary.compactAfterTurns else { return }
        let older = Array(turns.dropLast(CampingChatHistory.maximumTurns))
        // A failed summary leaves the turns in place; the next answer tries again.
        guard let folded = await folded(older, into: summary), generation == expected else { return }
        summary = folded
        for turn in older { forget(turn.id) }
    }

    /// Folds `turns` into `summary` a few at a time, each pass in its own short-lived session that carries the
    /// summary so far (TN3193). Nil when a pass fails.
    private func folded(_ turns: [CampingChatTurn], into summary: String?) async -> String? {
        var result = summary
        for start in stride(from: 0, to: turns.count, by: ConversationSummary.turnsPerPass) {
            let pass = Array(turns[start..<min(start + ConversationSummary.turnsPerPass, turns.count)])
            guard let text = try? await model.summarize(pass, into: result),
                  let cleaned = ConversationSummary.cleaned(text) else { return nil }
            result = cleaned
        }
        return result
    }

    private func currentSession() -> any CampingChatSession {
        if let session { return session }
        let made = model.makeSession(history: turns)
        session = made
        return made
    }

    private func cost(_ turn: CampingChatTurn) -> Int { costs[turn.id] ?? Self.estimate(turn) }

    private static func estimate(_ turn: CampingChatTurn) -> Int {
        ConservativeTokenEstimator.estimate(turn.question) + ConservativeTokenEstimator.estimate(turn.answer)
            + CampingChatHistory.turnOverheadTokens
    }

    /// Resolves citations against the manifest of whichever prompt reached the model.
    static func reply(_ text: String, to request: CampingHelpRequest, sent: PromptPlan) -> CampingReply {
        guard let documents = request.documents else {
            return CampingReply(text: text, sources: [], droppedCitationCount: 0, coverage: .notSearched,
                                readiness: .empty, usedSavedTrip: request.usesSavedTrip)
        }
        // With nothing supplied there is nothing citable, whatever the model wrote.
        let manifest = sent.sources
        let resolved = DocumentCitations.resolve(text, manifest: manifest)
        let unfinished = documents.readiness.hasUnusableDocuments
        let coverage: DocumentCoverage = manifest.isEmpty ? (unfinished ? .unfinished : .notCovered) : (resolved.sources.isEmpty ? .uncited : .cited)
        return CampingReply(text: resolved.text.isEmpty ? text : resolved.text, sources: resolved.sources,
                            droppedCitationCount: resolved.droppedCount, coverage: coverage,
                            readiness: documents.readiness, usedSavedTrip: request.usesSavedTrip,
                            searched: manifest.filter { !resolved.sources.contains($0) }, passages: sent.passages)
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
