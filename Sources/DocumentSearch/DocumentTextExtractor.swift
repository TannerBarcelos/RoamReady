#if canImport(PDFKit) && canImport(Vision) && canImport(ImageIO) && canImport(CoreGraphics)
import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics
import NaturalLanguage

/// Reads a document's text one page at a time, keeping each page's one-based ordinal and printed label.
/// A PDF page uses its own text layer when that is usable and is recognized with Vision when it isn't, so a
/// PDF that mixes typed and scanned pages has every page searchable. An image document is one page (a
/// multi-page TIFF is one page per frame). The limits and judgments are in `OCRPolicy`; this is the adapter
/// to PDFKit, ImageIO, and Vision. Document text is never logged.
public enum DocumentTextExtractor {
    /// Bump when extraction changes what the same file yields, so existing indexes are rebuilt.
    public static let version = 2
    public static let maximumPages = 1_000
    public static let maximumCharacters = 4_000_000

    public struct Extraction: Sendable {
        public var pages: [ExtractedPage]
        /// BCP-47-ish code such as "en", or "und" when the text is too short to tell.
        public var language: String
        public var isEnglish: Bool
        public var outcome: DocumentReadOutcome
    }

    /// Synchronous and CPU-bound: call it off the main actor. PDFKit and Vision objects never leave this
    /// function, and only one page bitmap exists at a time.
    public nonisolated static func extract(from data: Data, budget: OCRBudget = OCRBudget()) -> Extraction {
        let isPDF = data.starts(with: Array("%PDF-".utf8))
        let result = isPDF ? readPDF(data, budget: budget) : readImage(data, budget: budget)
        let pages: [ExtractedPage], recognized: Int, skipped: Int, failures: Int
        switch result {
        case .failed(let reason):
            return Extraction(pages: [], language: "und", isEnglish: true, outcome: .noUsableText(reason))
        case .pages(let read, let count, let left, let failed):
            (pages, recognized, skipped, failures) = (read, count, left, failed)
        }
        let hasText = pages.contains { OCRPolicy.alphanumericCount($0.text) > 0 }
        let (language, isEnglish) = detectLanguage(pages)
        let outcome: DocumentReadOutcome = hasText ? .ready(recognizedPages: recognized, skippedPages: skipped + failures)
            : (failures > 0 ? .retryLater : .noUsableText(.noText))
        return Extraction(pages: pages, language: language, isEnglish: isEnglish, outcome: outcome)
    }

    private enum ReadResult {
        case pages([ExtractedPage], recognized: Int, skipped: Int, failures: Int)
        case failed(NoUsableTextReason)
    }

    // MARK: PDF

    private nonisolated static func readPDF(_ data: Data, budget: OCRBudget) -> ReadResult {
        guard let document = PDFDocument(data: data) else { return .failed(.unreadable) }
        // A password-protected file is a final answer, not something to ask for or retry.
        if document.isLocked { return .failed(.encrypted) }
        let count = document.pageCount
        if count == 0 { return .failed(.empty) }

        var budget = budget
        let clock = ContinuousClock()
        let start = clock.now
        var pages: [ExtractedPage] = []
        var recognized = 0
        var skipped = max(0, count - maximumPages)
        var failures = 0
        var total = 0
        for index in 0..<min(count, maximumPages) {
            guard let page = document.page(at: index) else { continue }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var text = layer
            var confidence: Double?
            if !OCRPolicy.hasUsableTextLayer(layer) {
                if budget.admit(elapsed: start.duration(to: clock.now)) {
                    // Keep whichever reading has more to search; a one-line text layer beats a failed scan.
                    let attempt: Attempt = autoreleasepool { render(page).map { recognize($0).map(Attempt.read) ?? .failed } ?? .unrenderable }
                    var reading: RecognizedPage?
                    switch attempt {
                    case .read(let page): reading = page
                    case .failed: failures += 1
                    case .unrenderable: skipped += 1
                    }
                    if let reading, OCRPolicy.alphanumericCount(reading.text) > OCRPolicy.alphanumericCount(layer) {
                        text = reading.text
                        confidence = reading.confidence
                        recognized += 1
                    }
                } else {
                    skipped += 1
                }
            }
            total += text.count
            pages.append(ExtractedPage(ordinal: index + 1, label: page.label, text: text, ocrConfidence: confidence))
            if total > maximumCharacters { skipped += count - index - 1; break }
        }
        return .pages(pages, recognized: recognized, skipped: skipped, failures: failures)
    }

    private enum Attempt { case read(RecognizedPage), failed, unrenderable }

    /// Draws a page into a bounded 8-bit gray bitmap, upright whatever the page's /Rotate says.
    nonisolated static func render(_ page: PDFPage) -> CGImage? {
        guard let reference = page.pageRef else { return nil }
        let box = reference.getBoxRect(.cropBox)
        let sideways = reference.rotationAngle % 180 != 0
        let size = OCRPolicy.renderSize(width: Double(sideways ? box.height : box.width),
                                        height: Double(sideways ? box.width : box.height))
        guard !box.isEmpty, let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .high
        // getDrawingTransform only shrinks to fit, so it is asked for the page at its own size (which carries
        // the /Rotate and the box origin) and the scale up to the bitmap is applied outside it.
        let pageSize = CGSize(width: sideways ? box.height : box.width, height: sideways ? box.width : box.height)
        context.scaleBy(x: CGFloat(size.width) / pageSize.width, y: CGFloat(size.height) / pageSize.height)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        return context.makeImage()
    }

    // MARK: Images

    private nonisolated static func readImage(_ data: Data, budget: OCRBudget) -> ReadResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return .failed(.unreadable)
        }
        // Only a TIFF is a sequence of pages; a GIF's frames are an animation, not a document.
        let isTIFF = (CGImageSourceGetType(source) as String?) == "public.tiff"
        let frames = isTIFF ? min(CGImageSourceGetCount(source), OCRPolicy.maximumImageFrames) : 1
        var budget = budget
        let clock = ContinuousClock()
        let start = clock.now
        var pages: [ExtractedPage] = []
        var recognized = 0
        var skipped = isTIFF ? max(0, CGImageSourceGetCount(source) - frames) : 0
        var failures = 0
        for index in 0..<frames {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties?[kCGImagePropertyPixelHeight] as? Int else {
                if index == 0 { return .failed(.unreadable) }
                skipped += 1
                continue
            }
            guard OCRPolicy.isDecodable(pixelWidth: width, pixelHeight: height) else {
                if index == 0 { return .failed(.tooLarge) }
                skipped += 1
                continue
            }
            guard budget.admit(elapsed: start.duration(to: clock.now)) else { skipped += 1; continue }
            // The thumbnail decoder subsamples while decoding, applies the EXIF orientation, and never
            // returns more than the render edge, so the full-size bitmap is not kept.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: OCRPolicy.maximumRenderEdge
            ]
            let attempt: Attempt = autoreleasepool {
                CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
                    .map { recognize($0).map(Attempt.read) ?? .failed } ?? .unrenderable
            }
            guard case .read(let reading) = attempt else {
                if case .failed = attempt { failures += 1 } else if index == 0 { return .failed(.unreadable) } else { skipped += 1 }
                continue
            }
            recognized += 1
            pages.append(ExtractedPage(ordinal: index + 1, text: reading.text, ocrConfidence: reading.confidence))
        }
        return .pages(pages, recognized: recognized, skipped: skipped, failures: failures)
    }

    // MARK: Vision

    /// Reads the image upright, and again turned if that found little: scans are often fed in sideways.
    /// Nil when the recognizer itself failed, which is different from finding no text.
    private nonisolated static func recognize(_ image: CGImage) -> RecognizedPage? {
        guard let first = read(image, orientation: .up) else { return nil }
        guard OCRPolicy.shouldTryOtherRotations(first) else { return first }
        let turned = [CGImagePropertyOrientation.right, .left, .down].compactMap { read(image, orientation: $0) }
        return OCRPolicy.best(of: [first] + turned) ?? first
    }

    nonisolated static func read(_ image: CGImage, orientation: CGImagePropertyOrientation) -> RecognizedPage? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(text: candidate.string, confidence: Double(candidate.confidence),
                                  x: Double(box.minX), y: Double(box.minY), width: Double(box.width), height: Double(box.height))
        }
        return OCRPolicy.page(from: lines)
    }

    // MARK: Language

    private nonisolated static func detectLanguage(_ pages: [ExtractedPage]) -> (language: String, isEnglish: Bool) {
        let sample = String(pages.prefix(12).map(\.text).joined(separator: " ").prefix(4_000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let dominant = recognizer.dominantLanguage
        let english = recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0
        let isEnglish = dominant == nil || dominant == .undetermined || dominant == .english || english >= 0.4
        return (isEnglish ? "en" : (dominant?.rawValue ?? "und"), isEnglish)
    }
}
#endif
