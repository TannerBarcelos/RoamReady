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

    /// A new session per pass with only the summary instructions, so summarizing never touches the chat's own
    /// transcript or its context window (TN3193: split a large task across sessions).
    public func summarize(_ turns: [CampingChatTurn], into summary: String?) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw CampingChatFailure.notReady }
        let session = LanguageModelSession(model: model, instructions: ConversationSummary.instructions)
        let options = GenerationOptions(maximumResponseTokens: ConversationSummary.maximumResponseTokens)
        return try await session.respond(to: ConversationSummary.prompt(folding: turns, into: summary), options: options).content
    }
}

/// One `LanguageModelSession` per chat. Its transcript holds the conversation. This turn's instructions and
/// tools are `DynamicInstructions`, evaluated for each request and never stored as history. The framework runs
/// the tool loop. Only the newest stored turn keeps its tool calls and results, and the profile's history
/// transform sends them only when `CampingChat` names that turn; it sends only the turns `CampingChat` chose,
/// and a failed or cancelled request reverts the transcript.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleCampingChatSession: CampingChatSession {
    private let context = TurnContext()
    private let session: LanguageModelSession

    init(history: [CampingChatTurn]) {
        session = LanguageModelSession(profile: ChatProfile(context: context), history: history.flatMap(\.transcriptEntries))
    }

    func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String {
        try await respond(to: prompt, instructions: instructions, history: history, tools: nil, resultsOf: nil).text
    }

    func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                 tools: CampingTools?, resultsOf: CampingChatTurn.ID?) async throws -> CampingSessionReply {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw CampingChatFailure.notReady }
        guard model.supportsLocale() else { throw CampingChatFailure.unsupportedLanguage }
        try Task.checkCancellation()
        context.set(instructions: instructions, kept: Set(history.map(\.id)), tools: tools, resultsOf: resultsOf)
        do {
            // No cancellation check after this: a finished turn is in the transcript, and `CampingChat` stores
            // or drops it.
            let text = try await session.respond(to: prompt).content
            return CampingSessionReply(text: text, toolsUsed: context.toolsUsed, toolOutputs: context.toolOutputs)
        } catch is CancellationError {
            throw CancellationError()
        } catch is LanguageModelSession.ToolCallError {
            // The tools only read snapshots, so a failure here is the framework's; the transcript is reverted.
            if Task.isCancelled { throw CancellationError() }
            throw CampingChatFailure.failed
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

    func prewarm() {
        session.prewarm()
    }

    /// Swaps the raw prompt (with its excerpts) and response just added for the turn's stored form, keeping the
    /// turn's tool calls and results between them. Older turns lose theirs: only the newest turn keeps results.
    func store(_ turn: CampingChatTurn) {
        var history = session.properties.history
        guard let prompt = history.lastIndex(where: \.isPrompt) else { return }
        let older: [Transcript.Entry] = history[..<prompt].filter { !$0.isToolEntry }
        let tools: [Transcript.Entry] = history[history.index(after: prompt)...].filter(\.isToolEntry)
        let stored = turn.transcriptEntries
        // Same mutation style as `remove(_:)`, so the history keeps its own collection type.
        history.replaceSubrange(history.startIndex..<history.endIndex, with: older + [stored[0]] + tools + [stored[1]])
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

/// What the next request may use, and which tools it called. Set on the main actor before each call and read
/// by the framework and the tools while the request runs, so it's guarded.
@available(iOS 27.0, macOS 27.0, *)
private final class TurnContext: Sendable {
    private struct State {
        var instructions = ""
        var kept: Set<String> = []
        var tools: CampingTools?
        var resultsOf: String?
        var toolsUsed: Set<CampingToolKind> = []
        var toolOutputs: [String] = []
    }
    private let state = Mutex(State())

    var instructions: String { state.withLock { $0.instructions } }
    var kept: Set<String> { state.withLock { $0.kept } }
    var tools: CampingTools? { state.withLock { $0.tools } }
    var toolsUsed: Set<CampingToolKind> { state.withLock { $0.toolsUsed } }
    var toolOutputs: [String] { state.withLock { $0.toolOutputs } }
    var resultsOf: String? { state.withLock { $0.resultsOf } }

    func offers(_ kind: CampingToolKind) -> Bool { state.withLock { $0.tools?.kinds.contains(kind) == true } }

    /// A required tool is required until it's called; after that the model may answer (Apple: a required mode
    /// needs an exit condition, or the model keeps calling the tool).
    var callingMode: GenerationOptions.ToolCallingMode {
        state.withLock { state in
            guard let required = state.tools?.required, !state.toolsUsed.contains(required) else { return .allowed }
            return .required
        }
    }

    func set(instructions: String, kept: Set<String>, tools: CampingTools?, resultsOf: String?) {
        state.withLock { $0 = State(instructions: instructions, kept: kept, tools: tools, resultsOf: resultsOf) }
    }

    /// Records a call and returns its output, for the tools to return.
    func used(_ tool: CampingToolKind, output: String) -> String {
        state.withLock { state in
            state.toolsUsed.insert(tool)
            state.toolOutputs.append(output)
        }
        return output
    }
}

/// Re-evaluated before every model request, so a turn carries only the tool definitions it offers.
@available(iOS 27.0, macOS 27.0, *)
private struct TurnInstructions: DynamicInstructions {
    let context: TurnContext
    var body: some DynamicInstructions {
        Instructions(context.instructions)
        if context.offers(.trip) { TripTool(context: context) }
        if context.offers(.menu) { MenuTool(context: context) }
        if context.offers(.rig) { RigTool(context: context) }
    }
}

// The tools are thin: names, descriptions, and output come from `CampingTools` in `CampCore`, where they're
// tested without Foundation Models, over snapshots taken before the request.

@available(iOS 27.0, macOS 27.0, *)
private struct MenuTool: Tool {
    let context: TurnContext
    let name = CampingToolKind.menu.name
    let description = CampingToolKind.menu.description

    @Generable
    enum Meal {
        case breakfast, lunch, dinner, snack, other

        var kind: MealKind {
            switch self {
            case .breakfast: .breakfast
            case .lunch: .lunch
            case .dinner: .dinner
            case .snack: .snack
            case .other: .other
            }
        }
    }

    @Generable
    struct Arguments {
        @Guide(description: "Trip day number. Omit for every day.")
        var day: Int?
        @Guide(description: "Omit for every meal.")
        var meal: Meal?
    }

    func call(arguments: Arguments) async throws -> String {
        context.used(.menu, output: context.tools?.menuOutput(day: arguments.day, meal: arguments.meal?.kind) ?? "This trip has no menu.")
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct TripTool: Tool {
    let context: TurnContext
    let name = CampingToolKind.trip.name
    let description = CampingToolKind.trip.description

    @Generable
    enum Phase {
        case setup, teardown

        var phase: ChecklistPhase { self == .setup ? .setup : .teardown }
    }

    @Generable
    struct Arguments {
        @Guide(description: "Limit the checklist to one phase. Omit for both.")
        var checklist: Phase?
        @Guide(description: "True for only the checklist steps not done yet.")
        var remainingOnly: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        context.used(.trip, output: context.tools?.tripOutput(phase: arguments.checklist?.phase,
                                                               remainingOnly: arguments.remainingOnly ?? false) ?? "No trip is selected.")
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct RigTool: Tool {
    let context: TurnContext
    let name = CampingToolKind.rig.name
    let description = CampingToolKind.rig.description

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        context.used(.rig, output: context.tools?.rigOutput() ?? "No rig is saved.")
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct ChatProfile: LanguageModelSession.DynamicProfile {
    let context: TurnContext
    var body: some LanguageModelSession.DynamicProfile {
        Profile { TurnInstructions(context: context) }
            .historyTransform { [context] entries in
                CampingChatHistory.sent(entries, keeping: context.kept, resultsOf: context.resultsOf, kind: \.chatKind)
            }
            .toolCallingMode(context.callingMode)
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
        case .toolCalls, .toolOutput: .tool
        default: .other
        }
    }

    var isPrompt: Bool { if case .prompt = self { true } else { false } }

    var isToolEntry: Bool { chatKind == .tool }
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
