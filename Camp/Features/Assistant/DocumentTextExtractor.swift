import Foundation
import PDFKit
import NaturalLanguage
import DocumentSearch

/// Reads a PDF's text with PDFKit, one page at a time, keeping each page's one-based ordinal and printed
/// label. Pages without a text layer come back empty; text recognition for scans comes later.
enum DocumentTextExtractor {
    /// Bump when extraction changes what the same file yields, so existing indexes are rebuilt.
    static let version = 1
    static let maximumPages = 1_000
    static let maximumCharacters = 4_000_000

    struct Extraction: Sendable {
        var pages: [ExtractedPage]
        /// BCP-47-ish code such as "en", or "und" when the text is too short to tell.
        var language: String
        var isEnglish: Bool
    }

    /// Synchronous and CPU-bound: call it off the main actor. PDFKit objects never leave this function.
    nonisolated static func extract(from data: Data) -> Extraction? {
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        var pages: [ExtractedPage] = []
        var total = 0
        for index in 0..<min(document.pageCount, maximumPages) {
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            total += text.count
            pages.append(ExtractedPage(ordinal: index + 1, label: page.label, text: text))
            if total > maximumCharacters { break }
        }
        let sample = String(pages.prefix(12).map(\.text).joined(separator: " ").prefix(4_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let dominant = recognizer.dominantLanguage
        let english = recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0
        let isEnglish = dominant == nil || dominant == .undetermined || dominant == .english || english >= 0.4
        return Extraction(pages: pages, language: isEnglish ? "en" : (dominant?.rawValue ?? "und"), isEnglish: isEnglish)
    }
}
