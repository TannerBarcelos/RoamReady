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

/// A model that answers one turn on its own. `CampingChatModel` is the conversation form.
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
    /// The passage text the model was shown for each cited or searched source, by source ID.
    public var passages: [DocumentSource.ID: String] = [:]
    /// The chat turn this answer was stored as, so it can be asked again as of that point.
    public var turnID: CampingChatTurn.ID?
}

/// A single question with no conversation, through the same planning, overflow retry, and citation checks
/// as a chat. The app's conversations use `CampingChat`.
@MainActor
public enum CampingGeneration {
    public static func reply(to request: CampingHelpRequest, using generator: any CampingResponseGenerating,
                             counter: any PromptTokenCounting = ConservativeTokenEstimator()) async throws -> String {
        try await answer(to: request, using: generator, counter: counter).text
    }

    public static func answer(to request: CampingHelpRequest, using generator: any CampingResponseGenerating,
                              counter: any PromptTokenCounting = ConservativeTokenEstimator()) async throws -> CampingReply {
        try await CampingChat(model: SingleTurnChatModel(generator), counter: counter).answer(request)
    }
}
