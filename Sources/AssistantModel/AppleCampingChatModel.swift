import Foundation
import Synchronization
import CampCore
#if canImport(FoundationModels)
import FoundationModels

/// The sole production model, shared by the app and the eval command. `SystemLanguageModel.default` is Apple's
/// on-device model in its general-purpose configuration, the most capable model Foundation Models runs on
/// device. Private Cloud Compute and other server models are remote, so they wait for v2; there is no service fallback.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
public struct AppleCampingChatModel: CampingChatModel {
    public init() {}

    public func makeSession(history: [CampingChatTurn]) -> any CampingChatSession {
        AppleCampingChatSession(history: history)
    }
}

/// One `LanguageModelSession` per chat. Its transcript holds the conversation. This turn's instructions are
/// `DynamicInstructions`, evaluated for each request and never stored as history. The profile's history
/// transform sends only the turns `CampingChat` chose, and a failed or cancelled request reverts the transcript.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleCampingChatSession: CampingChatSession {
    private let context = TurnContext()
    private let session: LanguageModelSession

    init(history: [CampingChatTurn]) {
        session = LanguageModelSession(profile: ChatProfile(context: context), history: history.flatMap(\.transcriptEntries))
    }

    func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw CampingChatFailure.notReady }
        guard model.supportsLocale() else { throw CampingChatFailure.unsupportedLanguage }
        try Task.checkCancellation()
        context.set(instructions: instructions, kept: Set(history.map(\.id)))
        do {
            // No cancellation check after this: a finished turn is in the transcript, and `CampingChat` stores
            // or drops it.
            return try await session.respond(to: prompt).content
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

    /// Swaps the raw prompt (with its excerpts) and response just added for the turn's stored form.
    func store(_ turn: CampingChatTurn) {
        var history = session.properties.history
        guard let prompt = history.lastIndex(where: \.isPrompt) else { return }
        history.replaceSubrange(prompt..<history.endIndex, with: turn.transcriptEntries)
        session.properties.history = history
    }

    func remove(_ turnID: CampingChatTurn.ID) {
        var history = session.properties.history
        guard let start = history.firstIndex(where: { $0.chatKind == .prompt(id: turnID) }) else { return }
        let end = history[history.index(after: start)...].firstIndex(where: \.isPrompt)
        history.removeSubrange(start..<(end ?? history.endIndex))
        session.properties.history = history
    }
}

/// What the next request may use. Set on the main actor before each call and read by the framework while it
/// builds the request, so it's guarded.
@available(iOS 27.0, macOS 27.0, *)
private final class TurnContext: Sendable {
    private let state = Mutex<(instructions: String, kept: Set<String>)>(("", []))

    var instructions: String { state.withLock { $0.instructions } }
    var kept: Set<String> { state.withLock { $0.kept } }

    func set(instructions: String, kept: Set<String>) {
        state.withLock { $0 = (instructions, kept) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct TurnInstructions: DynamicInstructions {
    let context: TurnContext
    var body: some DynamicInstructions { Instructions(context.instructions) }
}

@available(iOS 27.0, macOS 27.0, *)
private struct ChatProfile: LanguageModelSession.DynamicProfile {
    let context: TurnContext
    var body: some LanguageModelSession.DynamicProfile {
        Profile { TurnInstructions(context: context) }
            .historyTransform { [context] entries in
                CampingChatHistory.sent(entries, keeping: context.kept, kind: \.chatKind)
            }
            .transcriptErrorHandlingPolicy(.revertTranscript)
            .maximumResponseTokens(PromptBudget.outputTokens)
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension CampingChatTurn {
    /// The prompt carries the turn's id, which is how the history transform recognizes it.
    var transcriptEntries: [Transcript.Entry] {
        [.prompt(Transcript.Prompt(id: id, segments: [.text(.init(content: question))])),
         .response(Transcript.Response(id: id + "-answer", segments: [.text(.init(content: answer))]))]
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension Transcript.Entry {
    var chatKind: CampingChatHistory.EntryKind {
        switch self {
        case .instructions: .instructions
        case .prompt(let prompt): .prompt(id: prompt.id)
        case .response: .response
        default: .other
        }
    }

    var isPrompt: Bool { if case .prompt = self { true } else { false } }
}

/// Token counts and the context window come from the model itself, so the budget never rests on a
/// characters-per-token guess. A failed count makes the planner fall back to its conservative estimator.
@available(iOS 27.0, macOS 27.0, *)
public struct AppleTokenCounter: PromptTokenCounting {
    public init() {}

    public var contextSize: Int? { SystemLanguageModel.default.contextSize }

    public func tokenCount(of text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }
}
#endif
