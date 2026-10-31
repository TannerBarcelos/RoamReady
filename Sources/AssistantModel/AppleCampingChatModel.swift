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
/// tool are `DynamicInstructions`, evaluated for each request and never stored as history. The framework runs
/// the tool loop; a turn's tool calls and results stay in the transcript only until `store(_:)` replaces the
/// turn with its stored form. The profile's history transform sends only the turns `CampingChat` chose, and a
/// failed or cancelled request reverts the transcript.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleCampingChatSession: CampingChatSession {
    private let context = TurnContext()
    private let session: LanguageModelSession

    init(history: [CampingChatTurn]) {
        session = LanguageModelSession(profile: ChatProfile(context: context), history: history.flatMap(\.transcriptEntries))
    }

    func respond(to prompt: String, instructions: String, history: [CampingChatTurn]) async throws -> String {
        try await respond(to: prompt, instructions: instructions, history: history, toolTurn: nil).text
    }

    func respond(to prompt: String, instructions: String, history: [CampingChatTurn],
                 toolTurn: CampingToolTurn?) async throws -> CampingSessionReply {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw CampingChatFailure.notReady }
        guard model.supportsLocale() else { throw CampingChatFailure.unsupportedLanguage }
        try Task.checkCancellation()
        context.set(instructions: instructions, kept: Set(history.map(\.id)), toolTurn: toolTurn)
        do {
            // No cancellation check after this: a finished turn is in the transcript, and `CampingChat` stores
            // or drops it.
            let text = try await session.respond(to: prompt).content
            return CampingSessionReply(text: text, toolsUsed: context.toolsUsed)
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

    /// Swaps the raw prompt (with its excerpts), the turn's tool calls and results, and the response just added for
    /// the turn's stored form, so results never carry into later turns: each answer looks up fresh data.
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

/// What the next request may use, and whether it called the tool. Set on the main actor before each call and
/// read by the framework and the tool while the request runs, so it's guarded.
@available(iOS 27.0, macOS 27.0, *)
private final class TurnContext: Sendable {
    private struct State {
        var instructions = ""
        var kept: Set<String> = []
        var toolTurn: CampingToolTurn?
        var allowance = CampingToolAllowance(tokens: 0)
        var toolsUsed: Set<CampingToolKind> = []
    }
    private let state = Mutex(State())

    var instructions: String { state.withLock { $0.instructions } }
    var kept: Set<String> { state.withLock { $0.kept } }
    var toolsUsed: Set<CampingToolKind> { state.withLock { $0.toolsUsed } }
    var offersTrip: Bool { state.withLock { $0.toolTurn != nil } }

    /// With a trip selected, the model must call `get_trip` before it may answer. Required stops once a call is
    /// made (Apple: a required mode needs an exit condition, or the model keeps calling).
    var callingMode: GenerationOptions.ToolCallingMode {
        state.withLock { $0.toolTurn != nil && $0.toolsUsed.isEmpty ? .required : .allowed }
    }

    func set(instructions: String, kept: Set<String>, toolTurn: CampingToolTurn?) {
        state.withLock {
            $0 = State(instructions: instructions, kept: kept, toolTurn: toolTurn,
                       allowance: toolTurn?.allowance ?? CampingToolAllowance(tokens: 0))
        }
    }

    /// Answers a call from the turn's snapshots within what the allowance has left, and records it.
    func call(_ call: CampingToolCall) -> String {
        state.withLock { state in
            let tools = state.toolTurn?.tools
            let output = tools?.output(for: call, allowance: &state.allowance) ?? "No trip is selected."
            state.toolsUsed.insert(call.kind)
            return output
        }
    }
}

/// Re-evaluated before every model request, so a turn without a trip carries no tool definition.
@available(iOS 27.0, macOS 27.0, *)
private struct TurnInstructions: DynamicInstructions {
    let context: TurnContext
    var body: some DynamicInstructions {
        Instructions(context.instructions)
        if context.offersTrip { TripTool(context: context) }
    }
}

/// Thin: the name, description, output, and its budget come from `CampingTools` in `CampCore`, where they're
/// tested without Foundation Models, over snapshots taken before the request.
@available(iOS 27.0, macOS 27.0, *)
private struct TripTool: Tool {
    let context: TurnContext
    let name = CampingToolKind.trip.name
    let description = CampingToolKind.trip.description

    @Generable
    enum Focus {
        case overview, booking, checklist, menu, everything

        var focus: TripFocus {
            switch self {
            case .overview: .overview
            case .booking: .booking
            case .checklist: .checklist
            case .menu: .menu
            case .everything: .everything
            }
        }
    }

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
    enum Phase {
        case setup, teardown

        var phase: ChecklistPhase { self == .setup ? .setup : .teardown }
    }

    @Generable
    struct Arguments {
        @Guide(description: "What to fetch.")
        var focus: Focus
        @Guide(description: "Menu: trip day number. Omit for every day.")
        var day: Int?
        @Guide(description: "Menu: omit for every meal.")
        var meal: Meal?
        @Guide(description: "Checklist: one phase. Omit for both.")
        var checklist: Phase?
        @Guide(description: "Checklist: true for only steps not done yet.")
        var remainingOnly: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        context.call(CampingToolCall(focus: arguments.focus.focus, day: arguments.day, meal: arguments.meal?.kind,
                                     phase: arguments.checklist?.phase, remainingOnly: arguments.remainingOnly ?? false))
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct ChatProfile: LanguageModelSession.DynamicProfile {
    let context: TurnContext
    var body: some LanguageModelSession.DynamicProfile {
        Profile { TurnInstructions(context: context) }
            .historyTransform { [context] entries in
                CampingChatHistory.sent(entries, keeping: context.kept, kind: \.chatKind)
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
