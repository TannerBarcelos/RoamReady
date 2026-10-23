import Foundation
import CampCore
#if canImport(FoundationModels)
import FoundationModels

/// The sole production generator. SystemLanguageModel.default runs on device;
/// there is no Private Cloud Compute or third-party service fallback.
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
            let result = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 512))
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
#endif
