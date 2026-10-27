import Foundation

/// Builds FTS5 MATCH expressions from untrusted text.
enum FTSQuery {
    static let maxTerms = 32
    static let maxTermLength = 64

    /// Every whitespace-separated chunk becomes one quoted phrase, so FTS5 operators (`AND`, `NOT`, `NEAR`,
    /// `col:`, `*`, `^`, parentheses) in the input are plain text. Terms are OR-ed and ranked by bm25.
    /// Returns nil when nothing searchable remains.
    static func match(from text: String) -> String? {
        var terms: [String] = []
        for chunk in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            // Control characters (including NUL) have no place in a phrase.
            let cleaned = String(chunk.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maxTermLength))
            guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            terms.append("\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            if terms.count == maxTerms { break }
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }
}
