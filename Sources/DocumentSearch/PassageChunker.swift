import Foundation

/// The text of one page as an extractor read it. Foundation-only so the chunking rules are testable
/// without PDFKit; the app's PDFKit adapter produces these.
public struct ExtractedPage: Equatable, Sendable {
    /// One-based position in the file.
    public var ordinal: Int
    /// The label printed on the page, when the file defines one.
    public var label: String?
    public var text: String

    public init(ordinal: Int, label: String? = nil, text: String) {
        self.ordinal = ordinal
        self.label = label
        self.text = text
    }
}

/// Turns extracted pages into evidence passages. A passage never crosses a page, so a citation's page is
/// exact; a heading starts a new passage and names the section of the passages that follow it.
public enum PassageChunker {
    /// Bump when the rules below change, so existing indexes are rebuilt.
    public static let version = 1
    /// Upper bound of a passage's text. Also keeps each passage within what a sentence embedding handles well.
    public static let maximumCharacters = 900
    static let minimumCharacters = 12
    static let maximumHeadingLength = 60

    public static func passages(from pages: [ExtractedPage]) -> [IndexedPassage] {
        var result: [IndexedPassage] = []
        var section: String?
        for page in pages {
            // A printed label is only worth keeping when it says something the ordinal doesn't.
            let label = page.label.flatMap { $0.isEmpty || $0 == String(page.ordinal) ? nil : $0 }
            var buffer = ""
            var hasBody = false
            func flush() {
                let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if hasBody, text.count >= minimumCharacters {
                    result.append(IndexedPassage(text: text, page: page.ordinal, section: section, pageLabel: label))
                }
                buffer = ""
                hasBody = false
            }
            for line in lines(of: page.text) {
                if isHeading(line) {
                    flush()
                    section = String(line.prefix(80))
                    buffer = line
                    continue
                }
                for piece in split(line) {
                    if !buffer.isEmpty, buffer.count + piece.count + 1 > maximumCharacters { flush() }
                    buffer += buffer.isEmpty ? piece : " " + piece
                    hasBody = true
                }
            }
            flush()
        }
        return result
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ") }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    /// Short, unpunctuated lines such as "TROUBLESHOOTING" or "Winterizing the water system".
    private static func isHeading(_ line: String) -> Bool {
        guard line.count <= maximumHeadingLength, line.split(separator: " ").count <= 8,
              let last = line.last, !".,;:!?".contains(last) else { return false }
        let letters = line.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        if letters.allSatisfy(\.isUppercase) { return true }
        // Title Case: every longer word starts with a capital letter.
        let words = line.split(separator: " ").filter { $0.count > 3 }
        return !words.isEmpty && words.allSatisfy { $0.first?.isUppercase == true } && line.split(separator: " ").count >= 2
    }

    /// A line longer than a passage is cut at sentence ends, then hard-cut on a space as a last resort.
    private static func split(_ line: String) -> [String] {
        guard line.count > maximumCharacters else { return [line] }
        var pieces: [String] = []
        var current = ""
        line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces) else { return }
            if !current.isEmpty, current.count + sentence.count + 1 > maximumCharacters {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.flatMap { hardCut($0) }
    }

    private static func hardCut(_ text: String) -> [String] {
        var rest = Substring(text)
        var out: [String] = []
        while rest.count > maximumCharacters {
            let limit = rest.index(rest.startIndex, offsetBy: maximumCharacters)
            let cut = rest[..<limit].lastIndex(of: " ") ?? limit
            out.append(String(rest[..<cut]))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}
