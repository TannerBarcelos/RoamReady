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

/// A testable send path. The app supplies Apple's on-device adapter; there is no remote adapter.
@MainActor
public enum CampingGeneration {
    public static func reply(to request: CampingHelpRequest, using generator: any CampingResponseGenerating) async throws -> String {
        try Task.checkCancellation()
        guard !request.questionExceedsLimit else { throw CampingChatFailure.contextTooLong }
        let response: String
        do {
            response = try await generator.respond(to: request.prompt, instructions: request.instructions)
        } catch CampingChatFailure.contextTooLong {
            // Each adapter call starts a fresh session. Retry once without old turns or long notes.
            try Task.checkCancellation()
            response = try await generator.respond(to: request.compactPrompt, instructions: request.instructions)
        }
        try Task.checkCancellation()
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CampingChatFailure.failed }
        return text
    }
}
