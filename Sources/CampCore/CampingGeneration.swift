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
}

public struct CampingReply: Equatable, Sendable {
    /// The answer with citation markers removed.
    public let text: String
    /// Only sources the model cited that were in the manifest of the prompt actually used.
    public let sources: [DocumentSource]
    public let droppedCitationCount: Int
    public let coverage: DocumentCoverage
}

/// A testable send path. The app supplies Apple's on-device adapter; there is no remote adapter.
@MainActor
public enum CampingGeneration {
    public static func reply(to request: CampingHelpRequest, using generator: any CampingResponseGenerating) async throws -> String {
        try await generate(request, using: generator).text
    }

    /// Like `reply`, and resolves citations against the manifest of whichever prompt reached the model.
    public static func answer(to request: CampingHelpRequest, using generator: any CampingResponseGenerating) async throws -> CampingReply {
        let (text, compact) = try await generate(request, using: generator)
        guard let documents = request.documents else {
            return CampingReply(text: text, sources: [], droppedCitationCount: 0, coverage: .notSearched)
        }
        // With nothing supplied there is nothing citable, whatever the model wrote.
        let manifest = documents.manifest(compact: compact)
        let resolved = DocumentCitations.resolve(text, manifest: manifest)
        let coverage: DocumentCoverage = manifest.isEmpty ? .notCovered : (resolved.sources.isEmpty ? .uncited : .cited)
        return CampingReply(text: resolved.text.isEmpty ? text : resolved.text, sources: resolved.sources,
                            droppedCitationCount: resolved.droppedCount, coverage: coverage)
    }

    private static func generate(_ request: CampingHelpRequest, using generator: any CampingResponseGenerating) async throws -> (text: String, compact: Bool) {
        try Task.checkCancellation()
        guard !request.questionExceedsLimit else { throw CampingChatFailure.contextTooLong }
        let response: String
        var compact = false
        do {
            response = try await generator.respond(to: request.prompt, instructions: request.instructions)
        } catch CampingChatFailure.contextTooLong {
            // Each adapter call starts a fresh session. Retry once without old turns or long notes.
            try Task.checkCancellation()
            compact = true
            response = try await generator.respond(to: request.compactPrompt, instructions: request.instructions)
        }
        try Task.checkCancellation()
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CampingChatFailure.failed }
        return (text, compact)
    }
}
