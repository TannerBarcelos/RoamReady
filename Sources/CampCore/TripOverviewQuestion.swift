import Foundation

/// A conservative fast path for requests to identify or summarize the saved trip. Task questions and
/// questions about documents stay on the normal help path, even when they mention a trip.
public enum TripOverviewQuestion {
    public static func matches(_ question: String) -> Bool {
        var words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.first == "please" { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        if words.count > 2, ["can", "could", "would"].contains(words[0]), words[1] == "you" {
            words.removeFirst(2)
        }
        let text = words.joined(separator: " ")
        let owner = "(?:my|our|this|the)"
        let trip = "\(owner) (?:(?:current|upcoming|next|planned|saved) )?trip"
        let patterns = [
            "(?:what|which) trip (?:is this|is that|am i (?:currently )?(?:planning|on)|are we (?:currently )?(?:planning|on))",
            "(?:what|which) is \(trip)",
            "(?:tell me about|what can you tell me about|summarize|describe|show me|show) \(trip)(?: details| summary| overview)?",
            "(?:give me|show me) (?:the |a )?(?:details|summary|overview) (?:of|for|about) \(trip)",
            "what are \(trip) (?:details|dates)",
            "(?:when|where) is \(trip)",
            "where (?:am i|are we) (?:going|camping|staying)(?: (?:on|for) \(trip))?"
        ]
        return patterns.contains { text.range(of: "^(?:\($0))$", options: .regularExpression) != nil }
    }
}
