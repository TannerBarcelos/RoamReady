import Foundation
import CampCore
#if canImport(FoundationModels)
import FoundationModels

/// The sole production generator. `SystemLanguageModel.default` is Apple's on-device model in its general-purpose
/// configuration, the most capable model Foundation Models runs on device. Private Cloud Compute and other
/// server models are remote, so they wait for v2; there is no service fallback.
@MainActor
struct AppleCampingResponseGenerator: CampingResponseGenerating {
    func respond(to prompt: String, instructions: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw CampingChatFailure.notReady }
        guard model.supportsLocale() else { throw CampingChatFailure.unsupportedLanguage }
        try Task.checkCancellation()
        // Fresh sessions plus bounded recent turns avoid an ever-growing model transcript.
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let result = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: PromptBudget.outputTokens))
            try Task.checkCancellation()
            return result.content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelError {
            if Task.isCancelled { throw CancellationError() }
            switch error {
            case .contextSizeExceeded: throw CampingChatFailure.contextTooLong
            case .unsupportedLanguageOrLocale: throw CampingChatFailure.unsupportedLanguage
            case .guardrailViolation, .refusal: throw CampingChatFailure.refused
            case .rateLimited: throw CampingChatFailure.busy
            default: throw CampingChatFailure.failed
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CampingChatFailure.failed
        }
    }
}

/// Token counts and the context window come from the model itself, so the budget never rests on a
/// characters-per-token guess. A failed count makes the planner fall back to its conservative estimator.
struct AppleTokenCounter: PromptTokenCounting {
    var contextSize: Int? { SystemLanguageModel.default.contextSize }

    func tokenCount(of text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }
}
#endif
