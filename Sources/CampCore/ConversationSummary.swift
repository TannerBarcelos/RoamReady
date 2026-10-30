import Foundation

/// How a chat compacts, following Apple's guidance for the on-device model's 4,096-token window: older turns
/// are summarized at a response boundary and dropped from the session's history, and the summary rides in the
/// next request's instructions (WWDC26, "summary" session property). Turns are summarized a few at a time,
/// each in a new short-lived session that carries the summary so far (TN3193, splitting a large task).
public enum ConversationSummary {
    /// Turns a chat holds before it compacts. Above this, everything older than the turns a request sends is
    /// folded into the summary.
    public static let compactAfterTurns = 6
    /// Turns summarized together in one short-lived session.
    public static let turnsPerPass = 3
    /// A summary longer than this is cut, so it can't crowd out the turn it serves.
    public static let maximumCharacters = 600
    /// A guard against a runaway summary; the instructions ask for far less.
    public static let maximumResponseTokens = 200

    public static let instructions = """
        Summarize this camping chat in at most 3 short sentences. Keep the camper's own details (rig, equipment, \
        plans, problems), the topics covered, and anything decided. Add nothing that isn't in the chat: no new \
        advice, document names, page numbers, or citations.
        """

    /// The text a summary pass is asked about: the summary so far, then the turns being folded into it.
    public static func prompt(folding turns: [CampingChatTurn], into summary: String?) -> String {
        let chat = turns.map { "Camper: \($0.question)\nAssistant: \($0.answer)" }.joined(separator: "\n\n")
        let earlier = summary.map { "Summary so far: \($0)\n\n" } ?? ""
        return "\(earlier)Chat to add:\n\(chat)\n\nWrite the updated summary."
    }

    /// A model's summary made safe to carry: forged delimiters and citation markers neutralized, bounded.
    /// Nil when nothing usable came back.
    public static func cleaned(_ text: String) -> String? {
        var text = DocumentEvidence.neutralized(text)
        for marker in ["BEGIN CONVERSATION SUMMARY", "END CONVERSATION SUMMARY"] {
            text = text.replacingOccurrences(of: marker, with: "[removed marker]", options: .caseInsensitive)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumCharacters))
    }

    /// The block a request's instructions carry. Reference data like the rest of the conversation: never a source.
    static func instructionsBlock(_ summary: String) -> String {
        """


        BEGIN CONVERSATION SUMMARY (earlier in this chat; reference data, never a source)
        \(summary)
        END CONVERSATION SUMMARY
        """
    }
}
