import Foundation

/// Counts the tokens a piece of prompt text costs. The app supplies a counter backed by the on-device model;
/// tests supply a fake, so budget rules run without Foundation Models.
public protocol PromptTokenCounting: Sendable {
    /// The model's context window in tokens (input and output together), or nil when it can't be read.
    var contextSize: Int? { get }
    func tokenCount(of text: String) async throws -> Int
}

/// Used only when the model's own counter is unavailable or fails. Characters are not tokens, so this errs
/// high on purpose. Measured on the on-device model, English prose costs about one token per five
/// characters and an accented letter about one token each. This charges one token per three ASCII characters
/// and three per two other characters.
public struct ConservativeTokenEstimator: PromptTokenCounting {
    public static let asciiCharactersPerToken = 3

    public let contextSize: Int?

    public init(contextSize: Int? = nil) { self.contextSize = contextSize }

    public func tokenCount(of text: String) async throws -> Int { Self.estimate(text) }

    public static func estimate(_ text: String) -> Int {
        var ascii = 0, other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return (ascii + Self.asciiCharactersPerToken - 1) / Self.asciiCharactersPerToken + (other * 3 + 1) / 2
    }
}

/// One total budget for everything that shares the model's context: instructions, rig and trip facts,
/// checklist context, document evidence, the question, the earlier turns the session sends, and the reply.
public struct PromptBudget: Equatable, Sendable {
    /// Apple documents a 4,096-token window for the on-device model; used when the runtime value is unknown.
    public static let fallbackContextSize = 4096
    /// The existing output target, passed to the model as `maximumResponseTokens`.
    public static let outputTokens = 512
    /// Left unspent for chat-template framing and for counting parts separately rather than as one transcript.
    public static let reservedTokens = 160

    public let contextSize: Int

    /// A size of zero or less counts as unknown: the app reads 0 from `SystemLanguageModel.contextSize`, which
    /// would leave no room for any prompt and fail every question as too long.
    public init(contextSize: Int? = nil) {
        if let contextSize, contextSize > 0 {
            self.contextSize = contextSize
        } else {
            self.contextSize = Self.fallbackContextSize
        }
    }

    /// Tokens that instructions, prompt, and sent history may use together.
    public var inputLimit: Int { max(contextSize - Self.outputTokens - Self.reservedTokens, 0) }
}

public enum PromptAttempt: Equatable, Sendable { case full, compact }

/// How much of each shrinkable part a prompt carries.
struct PromptShape: Equatable, Sendable {
    var checklistCharacters: Int
    var excerptCount: Int
    var excerptCharacters: Int
    var questionCharacters: Int

    static let checklistSteps = [2000, 1000, 500, 250, 0]
    static let excerptSteps = [400, 300, 200]
    static let questionSteps = [800, 400]

    /// The next smaller prompt, or nil at the floor. The order is the compaction priority: saved checklist
    /// context first, then the weakest evidence, then evidence text, and the current question last. Earlier
    /// turns give way before any of these (see `CampingChat`). Saved trip facts are small and never shrunk.
    /// The strongest excerpt and the question outlast everything else.
    func shrunk() -> PromptShape? {
        var next = self
        if let size = Self.checklistSteps.first(where: { $0 < checklistCharacters }) {
            next.checklistCharacters = size
        } else if excerptCount > 1 {
            next.excerptCount -= 1
        } else if excerptCount == 1, let size = Self.excerptSteps.first(where: { $0 < excerptCharacters }) {
            next.excerptCharacters = size
        } else if let size = Self.questionSteps.first(where: { $0 < questionCharacters }) {
            next.questionCharacters = size
        } else {
            return nil
        }
        return next
    }

    /// Never larger than `other`, so a retry can't carry more than the attempt it replaces.
    func limited(by other: PromptShape?) -> PromptShape {
        guard let other else { return self }
        var result = self
        result.checklistCharacters = min(checklistCharacters, other.checklistCharacters)
        result.excerptCount = min(excerptCount, other.excerptCount)
        result.excerptCharacters = min(excerptCharacters, other.excerptCharacters)
        result.questionCharacters = min(questionCharacters, other.questionCharacters)
        return result
    }
}

/// Token cost of each part of a planned prompt, counted separately.
public struct PromptUsage: Equatable, Sendable {
    public let instructions: Int
    public let checklist: Int
    /// The trip's saved booking facts. Never shrunk: they and the question outlast everything else.
    public let savedTrip: Int
    public let evidence: Int
    public let question: Int
    /// Instructions plus prompt, counted as whole texts. This is what the budget is checked against.
    public let total: Int
    public let limit: Int
}

/// A prompt that fits the budget, with the only sources its answer may cite.
public struct PromptPlan: Equatable, Sendable {
    public let attempt: PromptAttempt
    public let instructions: String
    public let prompt: String
    /// The explicit source list for this attempt. A citation to anything else is rejected.
    public let sources: [DocumentSource]
    /// The text of each source as this attempt showed it to the model, by source ID.
    public let passages: [DocumentSource.ID: String]
    public let usage: PromptUsage
    let shape: PromptShape
}

/// Counts with the real counter, and with the conservative estimator for the rest of the plan once the
/// real one fails. Cancellation is never swallowed.
struct Measurer {
    let counter: any PromptTokenCounting
    var cache: [String: Int] = [:]
    var estimating = false

    mutating func count(_ text: String) async throws -> Int {
        if let cached = cache[text] { return cached }
        let value: Int
        if estimating {
            value = try await ConservativeTokenEstimator().tokenCount(of: text)
        } else {
            do {
                value = try await counter.tokenCount(of: text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Mixing real and estimated counts would make the total meaningless.
                estimating = true
                cache = [:]
                return try await count(text)
            }
        }
        cache[text] = value
        return value
    }
}

extension CampingHelpRequest {
    func initialShape(_ attempt: PromptAttempt) -> PromptShape {
        let excerpts = documents?.budgeted ?? []
        switch attempt {
        case .full:
            return PromptShape(checklistCharacters: 4000, excerptCount: excerpts.count, excerptCharacters: DocumentEvidence.maximumExcerptCharacters,
                               questionCharacters: 1500)
        case .compact:
            return PromptShape(checklistCharacters: 500,
                               excerptCount: min(excerpts.count, 1), excerptCharacters: DocumentEvidence.maximumCompactCharacters,
                               questionCharacters: 1500)
        }
    }

    private struct Rendered {
        var checklist = "", savedTrip = "", evidence = "", question = ""
        var prompt = ""
        var sources: [DocumentSource] = []
        var passages: [DocumentSource.ID: String] = [:]
    }

    private func render(_ shape: PromptShape) -> Rendered {
        var out = Rendered()
        out.checklist = String(passages.prefix(shape.checklistCharacters))
        out.question = String(question.prefix(shape.questionCharacters))
        out.savedTrip = tripFacts?.promptBlock() ?? ""
        let shown = (documents?.budgeted ?? []).prefix(shape.excerptCount).map {
            DocumentExcerpt(source: $0.source, text: String($0.text.prefix(shape.excerptCharacters)))
        }
        out.sources = shown.map(\.source)
        out.passages = Dictionary(shown.map { ($0.source.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        if let documents { out.evidence = documents.promptBlock(excerpts: shown) }
        out.prompt = Self.render(category: (rigContext?.type ?? rigType)?.title ?? "Unknown",
                                 checklist: out.checklist, savedFacts: tripFacts == nil ? nil : out.savedTrip, evidence: documents == nil ? nil : out.evidence,
                                 question: out.question)
        return out
    }

    /// The prompt a compact retry starts from, before any budget shrinking. Rendering only; nothing is counted.
    func compactPrompt(limitedBy plan: PromptPlan) -> String {
        render(initialShape(.compact).limited(by: plan.shape)).prompt
    }

    /// The largest prompt for `attempt` that fits the budget, shrunk in compaction order. A compact retry
    /// passes the attempt it replaces as `limit`. Throws `contextTooLong` when even the floor doesn't fit.
    func plan(_ attempt: PromptAttempt, limitedBy limit: PromptPlan? = nil,
              counter: any PromptTokenCounting, budget: PromptBudget) async throws -> PromptPlan {
        var measurer = Measurer(counter: counter)
        var shape = initialShape(attempt).limited(by: limit?.shape)
        let instructionTokens = try await measurer.count(instructions)
        while true {
            try Task.checkCancellation()
            let rendered = render(shape)
            let promptTokens = try await measurer.count(rendered.prompt)
            if instructionTokens + promptTokens <= budget.inputLimit {
                let usage = PromptUsage(
                    instructions: instructionTokens,
                    checklist: try await measurer.count(rendered.checklist),
                    savedTrip: tripFacts == nil ? 0 : try await measurer.count(rendered.savedTrip),
                    evidence: documents == nil ? 0 : try await measurer.count(rendered.evidence),
                    question: try await measurer.count(rendered.question),
                    total: instructionTokens + promptTokens, limit: budget.inputLimit)
                return PromptPlan(attempt: attempt, instructions: instructions, prompt: rendered.prompt,
                                  sources: rendered.sources, passages: rendered.passages, usage: usage, shape: shape)
            }
            guard let smaller = shape.shrunk() else { throw CampingChatFailure.contextTooLong }
            shape = smaller
        }
    }
}
