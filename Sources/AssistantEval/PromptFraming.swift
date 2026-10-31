import Foundation

/// Evidence needs one enclosing frame; an empty retrieval must leave no document block in the prompt.
enum PromptFraming {
    static func failure(in prompt: String, expectsEvidence: Bool, name: String) -> String? {
        let begin = "BEGIN DOCUMENT EXCERPTS", end = "END DOCUMENT EXCERPTS"
        let begins = prompt.components(separatedBy: begin).count - 1
        let ends = prompt.components(separatedBy: end).count - 1
        guard expectsEvidence else {
            return begins == 0 && ends == 0 ? nil : "The \(name) has an excerpt delimiter without evidence."
        }
        guard begins == 1, ends == 1,
              let start = prompt.range(of: begin), let finish = prompt.range(of: end),
              start.upperBound <= finish.lowerBound else {
            return "The \(name) has a forged, missing, or misplaced excerpt delimiter."
        }
        return nil
    }
}
