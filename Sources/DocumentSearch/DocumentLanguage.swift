import Foundation

/// Reads how likely a text is to be in each language. The rules below decide what to do with the answer, so
/// they can be tested with a fake; the app uses `NaturalLanguageDetector`.
public protocol LanguageDetecting: Sendable {
    /// Probability per language code ("en", "es"), in any order. Empty when the text can't be read at all.
    func hypotheses(for text: String) -> [String: Double]
}

/// How much of a document the Assistant can read, now that document questions are English only.
public enum DocumentLanguageCoverage: String, Equatable, Sendable {
    /// Every passage is confidently English.
    case full
    /// Some passages were left out because they are another language or couldn't be classified.
    case partial
    /// No passage could be admitted: the document stays viewable and shareable but is not used as evidence.
    case englishOnly
}

/// The passages of one document that may enter retrieval.
public struct EnglishAdmission: Equatable, Sendable {
    public var admitted: [IndexedPassage]
    public var coverage: DocumentLanguageCoverage
    /// "en" when anything was admitted, else the most common language that was left out, or "und".
    public var language: String
    public var excludedCount: Int
}

public enum DocumentQuestionLanguage: Equatable, Sendable {
    case proceed
    /// The question is confidently in another language: explain, and invite an English question.
    case needsEnglish
}

/// Document Q&A is English only in this version. Language comes from substantive words, never from file
/// names, isolated codes, or part numbers, and each passage is judged on its own so a bilingual manual
/// still contributes its English pages.
public enum DocumentLanguagePolicy {
    // Changing these changes which passages are admitted: bump `PassageChunker.version`.
    static let minimumPassageWords = 5
    static let minimumQuestionWords = 3
    /// A passage is English only at this probability or higher; anything between is "uncertain" and left out.
    static let englishAtLeast = 0.75
    static let shortPassageWords = 12
    static let shortEnglishAtLeast = 0.55
    static let otherLanguageAtLeast = 0.6
    /// A question is turned away only when English is this unlikely.
    static let questionEnglishBelow = 0.15
    static let questionOtherAtLeast = 0.7

    public static let englishOnlyExplanation = "Asking about your documents works in English for now. Ask again in English and I’ll look through them. I don’t translate, so nothing here is guessed from another language."

    enum Judgment: Equatable {
        case english
        case other(String)
        case uncertain
        /// Too little prose to tell: a code, a part number, a table row.
        case neutral
    }

    // MARK: Passages

    /// Keeps the confidently English passages. A passage with too little prose to judge (a fault-code row)
    /// takes the language of its page, or of the document when its page has no prose; it is never
    /// admitted on its own say-so.
    public static func admit(_ passages: [IndexedPassage], using detector: any LanguageDetecting) -> EnglishAdmission {
        let judgments = passages.map { judge($0.text, minimumWords: minimumPassageWords, using: detector) }

        struct Tally { var english = 0, rest = 0 }
        var byPage: [Int?: Tally] = [:]
        var document = Tally()
        for (passage, judgment) in zip(passages, judgments) {
            switch judgment {
            case .english: byPage[passage.page, default: Tally()].english += 1; document.english += 1
            case .other, .uncertain: byPage[passage.page, default: Tally()].rest += 1; document.rest += 1
            case .neutral: break
            }
        }

        var admitted: [IndexedPassage] = []
        var leftOut: [String] = []
        for (passage, judgment) in zip(passages, judgments) {
            let keep: Bool
            switch judgment {
            case .english: keep = true
            case .other(let code): keep = false; leftOut.append(code)
            case .uncertain: keep = false
            case .neutral:
                let page = byPage[passage.page] ?? Tally()
                keep = page.english + page.rest > 0 ? page.english > 0 && page.rest == 0 : document.english > document.rest
            }
            if keep { admitted.append(passage) }
        }
        let excluded = passages.count - admitted.count
        let counts = Dictionary(grouping: leftOut, by: { $0 }).mapValues(\.count)
        let language = admitted.isEmpty ? (counts.max { $0.value < $1.value }?.key ?? "und") : "en"
        return EnglishAdmission(admitted: admitted,
                                coverage: admitted.isEmpty ? .englishOnly : (excluded > 0 ? .partial : .full),
                                language: language, excludedCount: excluded)
    }

    // MARK: Questions

    /// Whether to answer a document question. Only a question that is confidently another language is
    /// turned away. Anything short, or made of codes ("E4?", "A-203"), proceeds: the code itself is the
    /// query, and its language can't be known.
    public static func check(question: String, using detector: any LanguageDetecting) -> DocumentQuestionLanguage {
        let words = prose(in: question)
        guard words.count >= minimumQuestionWords else { return .proceed }
        let scores = detector.hypotheses(for: words.joined(separator: " "))
        let english = scores["en"] ?? 0
        guard english < questionEnglishBelow,
              let strongest = scores.filter({ $0.key != "en" }).values.max(), strongest >= questionOtherAtLeast
        else { return .proceed }
        return .needsEnglish
    }

    // MARK: Internals

    static func judge(_ text: String, minimumWords: Int, using detector: any LanguageDetecting) -> Judgment {
        let words = prose(in: text)
        guard words.count >= minimumWords else { return .neutral }
        let scores = detector.hypotheses(for: words.joined(separator: " "))
        let english = scores["en"] ?? 0
        if english >= englishAtLeast { return .english }
        // A few words, such as a fault-code table's labels, never reach full confidence; English is accepted
        // there when it clearly leads.
        let runnerUp = scores.filter { $0.key != "en" }.values.max() ?? 0
        if words.count < shortPassageWords, english >= shortEnglishAtLeast, english >= 3 * runnerUp { return .english }
        if let top = scores.filter({ $0.key != "en" }).max(by: { $0.value < $1.value }), top.value >= otherLanguageAtLeast {
            return .other(top.key)
        }
        return .uncertain
    }

    /// The words that carry a language: letters only. Anything with a digit is a code or a measurement,
    /// and single letters are fragments such as the "A" of "A-203".
    static func prose(in text: String) -> [String] {
        let tokens: [Substring] = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "’" && $0 != "'" })
        return tokens.filter { $0.count >= 2 && !$0.contains(where: { $0.isNumber }) }.map { String($0) }
    }
}

#if canImport(NaturalLanguage)
import NaturalLanguage

/// Apple's on-device language recognizer.
public struct NaturalLanguageDetector: LanguageDetecting {
    public init() {}

    public func hypotheses(for text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(recognizer.languageHypotheses(withMaximum: 5).map { ($0.key.rawValue, $0.value) },
                          uniquingKeysWith: max)
    }
}
#endif
