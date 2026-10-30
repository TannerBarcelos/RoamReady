import Foundation

public enum CampingChatFailure: Error, Equatable, LocalizedError, Sendable {
    case notReady, unsupportedLanguage, contextTooLong, refused, busy, failed

    public var errorDescription: String? {
        switch self {
        case .notReady: "Apple Intelligence isn’t ready. Check its settings and try again."
        case .unsupportedLanguage: "Apple’s on-device model doesn’t support this language. Try a supported language."
        case .contextTooLong: "This request is too long for the on-device model. Shorten your question or start a new chat."
        case .refused: "Apple’s on-device model couldn’t answer this request. Try rephrasing your question."
        case .busy: "Apple’s on-device model is busy. Wait a moment, then try again."
        case .failed: "The on-device model couldn’t finish this response. Your question is ready to try again."
        }
    }
}

@MainActor
public protocol CampingResponseGenerating {
    func respond(to prompt: String, instructions: String) async throws -> String
}

/// How an answer relates to the owner's documents.
public enum DocumentCoverage: Equatable, Sendable {
    /// No documents were in scope or searched.
    case notSearched
    /// Documents were searched and none was relevant.
    case notCovered
    /// Relevant excerpts were supplied but the answer cites none of them: general advice.
    case uncited
    case cited
    /// Nothing relevant was found, and some documents in scope couldn't be searched (still indexing, waiting
    /// for download, unreadable). The answer can't yet speak for them.
    case unfinished
}

public struct CampingReply: Equatable, Sendable {
    /// The answer with citation markers removed.
    public let text: String
    /// Only sources the model cited that were in the manifest of the prompt actually used.
    public let sources: [DocumentSource]
    public let droppedCitationCount: Int
    public let coverage: DocumentCoverage
    /// Readiness of the request's scope when it was asked.
    public let readiness: ScopeReadiness
    /// The question was about the booking and the saved trip's facts were supplied, so they are a source too.
    public let usedSavedTrip: Bool
    /// Excerpts the model was given and did not cite. Shown as references searched, never as sources.
    public var searched: [DocumentSource] = []
}

/// A testable send path. The app supplies Apple's on-device adapter; there is no remote adapter.
@MainActor
public enum CampingGeneration {
    public static func reply(to request: CampingHelpRequest, using generator: any CampingResponseGenerating,
                             counter: any PromptTokenCounting = ConservativeTokenEstimator()) async throws -> String {
        try await generate(request, using: generator, counter: counter).text
    }

    /// Like `reply`, and resolves citations against the manifest of whichever prompt reached the model.
    public static func answer(to request: CampingHelpRequest, using generator: any CampingResponseGenerating,
                              counter: any PromptTokenCounting = ConservativeTokenEstimator()) async throws -> CampingReply {
        let (text, sent) = try await generate(request, using: generator, counter: counter)
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
                            readiness: request.documents?.readiness ?? .empty, usedSavedTrip: request.usesSavedTrip,
                            searched: manifest.filter { !resolved.sources.contains($0) })
    }

    private static func generate(_ request: CampingHelpRequest, using generator: any CampingResponseGenerating,
                                 counter: any PromptTokenCounting) async throws -> (text: String, sent: PromptPlan) {
        try Task.checkCancellation()
        guard !request.questionExceedsLimit else { throw CampingChatFailure.contextTooLong }
        let budget = PromptBudget(contextSize: counter.contextSize)
        var plan = try await request.plan(.full, counter: counter, budget: budget)
        let response: String
        do {
            response = try await generator.respond(to: plan.prompt, instructions: plan.instructions)
        } catch CampingChatFailure.contextTooLong {
            // Each adapter call starts a fresh session. Retry once with its own, smaller source list; it never
            // carries more than the attempt it replaces.
            try Task.checkCancellation()
            let retry = try await request.plan(.compact, limitedBy: plan, counter: counter, budget: budget)
            guard retry.prompt != plan.prompt else { throw CampingChatFailure.contextTooLong }
            plan = retry
            response = try await generator.respond(to: plan.prompt, instructions: plan.instructions)
        }
        try Task.checkCancellation()
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CampingChatFailure.failed }
        return (text, plan)
    }
}
