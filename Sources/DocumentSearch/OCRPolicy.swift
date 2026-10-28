import Foundation

/// Why a document has nothing the Assistant can read. Each is a final answer for that file, not a failure to
/// retry: the document is recorded as indexed-with-no-text and is read again only when it changes.
public enum NoUsableTextReason: Equatable, Sendable {
    /// A PDF with no pages.
    case empty
    /// A PDF that needs a password to open.
    case encrypted
    /// Not a file PDFKit or ImageIO can open.
    case unreadable
    /// An image larger than `OCRPolicy.maximumSourcePixels`.
    case tooLarge
    /// Every page was read (or recognized) and none held text: blank pages, a photo of a landscape.
    case noText
}

public enum DocumentReadOutcome: Equatable, Sendable {
    /// Some text was read. `skippedPages` are pages left unread because a cap was reached.
    case ready(recognizedPages: Int, skippedPages: Int)
    case noUsableText(NoUsableTextReason)
    /// The recognizer itself failed (for example while its model was still preparing) and nothing else was
    /// readable. Unlike `noUsableText` this says nothing about the file, so nothing is recorded and the next
    /// sync tries again. That is one attempt per sync, never a loop.
    case retryLater
}

/// One line of recognized text with where it sat on the page, in Vision's normalized coordinates (origin at
/// the bottom left, so a larger `y` is higher on the page).
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.confidence = confidence; self.x = x; self.y = y; self.width = width; self.height = height
    }

    var midY: Double { y + height / 2 }
}

/// A page as recognized: its text in reading order and how sure the recognizer was of it.
public struct RecognizedPage: Equatable, Sendable {
    public var text: String
    /// Length-weighted mean of the lines' confidence, 0...1. Nil when nothing was recognized.
    public var confidence: Double?

    public init(text: String, confidence: Double?) { self.text = text; self.confidence = confidence }

    /// How much usable text, weighted by how much to trust it. Compares two readings of the same page.
    var score: Double { Double(OCRPolicy.alphanumericCount(text)) * (confidence ?? 0) }
}

/// The limits and judgments around reading scans. The 50 MiB file cap bounds the stored bytes, not the
/// decoded size: a small PDF can declare a page tens of thousands of points wide, and a small PNG can
/// decode to hundreds of megabytes. So every page is rendered to a bounded bitmap, only one bitmap exists at
/// a time, and the amount of recognition work is capped. Foundation-only so the rules are tested everywhere;
/// the Vision, PDFKit, and ImageIO adapter is `DocumentTextExtractor`.
public enum OCRPolicy {
    /// Longest side of the bitmap handed to the recognizer, in pixels (about 200 dpi on a letter page).
    public static let maximumRenderEdge = 2_400
    /// Largest bitmap in pixels. As 8-bit gray that is about 5 MB; a decoded image thumbnail in RGBA is 4x that.
    public static let maximumRenderPixels = 5_000_000
    /// Pages are drawn at most this many times their size in points (216 dpi), so small pages aren't blown up.
    public static let maximumRenderScale = 3.0
    /// Pages recognized per document. Later pages without a text layer stay unread.
    public static let maximumRecognizedPages = 120
    /// Wall-clock allowance for all recognition in one document.
    public static let maximumRecognitionTime: Duration = .seconds(240)
    /// Frames read from a multi-page TIFF.
    public static let maximumImageFrames = 40
    /// Image documents above this many pixels are not decoded.
    public static let maximumSourcePixels = 64_000_000
    /// A text layer shorter than this (letters and digits) is treated as missing: a scan with only a page number.
    public static let minimumTextLayerCharacters = 20
    /// Lines the recognizer is this unsure of are noise and are dropped.
    public static let minimumLineConfidence = 0.3
    /// A first reading weaker than this is retried with the page turned.
    static let minimumConfidentCharacters = 40
    static let minimumConfidentConfidence = 0.5

    // MARK: Which pages need recognition

    /// Whether a page's own text layer is good enough to index: enough letters and digits, and not mostly
    /// replacement or control characters (a broken font encoding).
    public static func hasUsableTextLayer(_ text: String) -> Bool {
        guard alphanumericCount(text) >= minimumTextLayerCharacters else { return false }
        let visible = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !visible.isEmpty else { return false }
        let broken = visible.filter {
            $0 == "\u{FFFD}" || $0.properties.generalCategory == .control || $0.properties.generalCategory == .privateUse
        }.count
        return Double(broken) / Double(visible.count) < 0.2
    }

    static func alphanumericCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
    }

    // MARK: Bounded rendering

    /// The bitmap size for a page of the given size in points: scaled to fit both the edge and the pixel cap,
    /// never beyond `maximumRenderScale`, and at least one pixel on each side.
    public static func renderSize(width: Double, height: Double) -> (width: Int, height: Int) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return (1, 1) }
        let scale = min(maximumRenderScale,
                        Double(maximumRenderEdge) / max(width, height),
                        (Double(maximumRenderPixels) / (width * height)).squareRoot())
        return (max(1, Int((width * scale).rounded(.down))), max(1, Int((height * scale).rounded(.down))))
    }

    /// Whether an image of this size may be decoded at all.
    public static func isDecodable(pixelWidth: Int, pixelHeight: Int) -> Bool {
        pixelWidth > 0 && pixelHeight > 0 && pixelWidth <= Int.max / pixelHeight
            && pixelWidth * pixelHeight <= maximumSourcePixels
    }

    // MARK: Rotation

    /// A reading this thin or this unsure may be a sideways or upside-down page, so the others are tried.
    public static func shouldTryOtherRotations(_ first: RecognizedPage) -> Bool {
        alphanumericCount(first.text) < minimumConfidentCharacters || (first.confidence ?? 0) < minimumConfidentConfidence
    }

    /// A turned reading must beat the upright one clearly. A short page read sideways often yields the same
    /// words with one or two more characters recognized, and taking that would scramble a table's rows.
    static let rotationMargin = 1.25

    /// The first reading (upright) unless a later one has clearly more trustworthy text; then the best of those.
    public static func best(of readings: [RecognizedPage]) -> RecognizedPage? {
        guard let upright = readings.first else { return nil }
        let turned = readings.dropFirst().filter { $0.score > upright.score * rotationMargin }
        return turned.reduce(upright) { $1.score > $0.score ? $1 : $0 }
    }

    // MARK: Layout

    /// Lines in reading order. Lines on one row are merged only when each is short, which is what table
    /// cells are, and joined with " | " so a label stays beside its value ("Front tires | 35 psi"). Long
    /// lines are prose: they stay separate, top to bottom, so a two-column page isn't spliced mid-sentence.
    public static func page(from lines: [RecognizedLine]) -> RecognizedPage {
        let kept = lines.filter {
            $0.confidence >= minimumLineConfidence && $0.text.contains(where: { $0.isLetter || $0.isNumber })
        }
        guard !kept.isEmpty else { return RecognizedPage(text: "", confidence: nil) }
        let heights = kept.map(\.height).sorted()
        let tolerance = heights[heights.count / 2] * 0.6
        var rows: [[RecognizedLine]] = []
        for line in kept.sorted(by: { $0.midY > $1.midY }) {
            if let anchor = rows.last?.first, abs(anchor.midY - line.midY) <= tolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var output: [String] = []
        for row in rows {
            let ordered = row.sorted { $0.x < $1.x }
            if ordered.count > 1, ordered.allSatisfy({ $0.width < 0.35 }) {
                output.append(ordered.map(\.text).joined(separator: " | "))
            } else {
                output.append(contentsOf: ordered.map(\.text))
            }
        }
        let weight = kept.reduce(0.0) { $0 + Double(max($1.text.count, 1)) }
        let confidence = kept.reduce(0.0) { $0 + $1.confidence * Double(max($1.text.count, 1)) } / weight
        return RecognizedPage(text: output.joined(separator: "\n"), confidence: confidence)
    }
}

/// Spends the page and time allowances for one document. Pure, so the order of events is testable:
/// the caller passes how long recognition has run.
public struct OCRBudget: Equatable, Sendable {
    public private(set) var pagesRemaining: Int
    public let timeLimit: Duration

    public init(pages: Int = OCRPolicy.maximumRecognizedPages, timeLimit: Duration = OCRPolicy.maximumRecognitionTime) {
        pagesRemaining = pages
        self.timeLimit = timeLimit
    }

    /// Takes one page from the allowance if both it and the time allow another.
    public mutating func admit(elapsed: Duration) -> Bool {
        guard pagesRemaining > 0, elapsed < timeLimit else { return false }
        pagesRemaining -= 1
        return true
    }
}
