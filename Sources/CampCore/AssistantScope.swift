import Foundation

/// What a question may draw on, in words the camper sees in chat.
public struct AssistantScopeSummary: Equatable, Hashable, Sendable {
    public let rigName: String?
    public let tripName: String?
    public let rigIsArchived: Bool

    public init(rigName: String?, tripName: String? = nil, rigIsArchived: Bool = false) {
        self.rigName = rigName; self.tripName = tripName; self.rigIsArchived = rigIsArchived
    }

    /// "Rig: Forest River No Boundaries", or "Trip: Pines · Rig: Forest River No Boundaries (archived)".
    public var text: String {
        let rig: String
        if let rigName {
            rig = "Rig: \(rigName)\(rigIsArchived ? " (archived)" : "")"
        } else {
            rig = tripName == nil ? "No active rig" : "Rig unavailable"
        }
        guard let tripName else { return rig }
        return "Trip: \(tripName) · \(rig)"
    }

    public var accessibilityText: String { "Assistant scope. " + text }
}

/// One finished exchange, tagged with the scope it was asked in.
public struct ScopedChatTurn<Scope: Hashable & Sendable>: Sendable {
    public let scope: Scope
    public let question: String
    public let answer: String

    public init(scope: Scope, question: String, answer: String) {
        self.scope = scope; self.question = question; self.answer = answer
    }
}

/// How a conversation carries into the next question. A conversation can span scopes (the active rig can
/// change while the global chat is open); only the current scope's turns may reach the next prompt, so one
/// rig's or trip's details never leak into another.
public enum AssistantConversationRules {
    public static func history<Scope>(_ turns: [ScopedChatTurn<Scope>], in scope: Scope) -> [CampingChatTurn] {
        turns.filter { $0.scope == scope }
            .suffix(CampingHelpRequest.maximumHistoryTurns)
            .map { CampingChatTurn(question: $0.question, answer: $0.answer) }
    }

    /// The text document retrieval runs on. A follow-up such as "how long do I wait?" is searched together
    /// with the previous user question. Generated answers are never part of it, so earlier model text can't
    /// become evidence, and a question from another scope is never included (`history` is already scoped).
    public static func retrievalQuestion(_ question: String, after history: [CampingChatTurn]) -> String {
        (history.suffix(1).map(\.question) + [question]).joined(separator: " ")
    }
}
