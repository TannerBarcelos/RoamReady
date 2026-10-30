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

/// How a conversation carries into the next question. A conversation can span scopes (the active rig can
/// change while the global chat is open); `CampingChat` drops the earlier turns when the scope changes, so one
/// rig's or trip's details never leak into another.
public enum AssistantConversationRules {
    /// The text document retrieval runs on. A follow-up such as "how long do I wait?" is searched together
    /// with the previous user question in the same scope. Generated answers are never part of it, so earlier
    /// model text can't become evidence.
    public static func retrievalQuestion(_ question: String, after previousQuestion: String?) -> String {
        ([previousQuestion].compactMap { $0 } + [question]).joined(separator: " ")
    }
}
