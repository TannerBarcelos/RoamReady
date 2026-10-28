#if canImport(Vision) && canImport(PDFKit) && canImport(CoreText)
import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
@testable import DocumentSearch

/// Real Vision, PDFKit, and ImageIO on generated fixtures: nothing here is a stored private document. The
/// fixtures are drawn at test time, so a scanned page is a bitmap of text with no text layer at all.
final class DocumentTextExtractorTests: XCTestCase {
    static let torque = ["Wheel and tire service", "Torque the lug nuts to 110 ft-lb after the first fifty miles.",
                         "Check the tire pressure before every trip."]
    static let winter = ["Winterizing the water system", "Drain the fresh water tank before winter storage.",
                         "Open every faucet and the low point drains."]

    /// The first recognition on a machine can fail or take a long time while Vision prepares its model, which
    /// is also what `retryLater` is for. Wait until it works so the assertions below test the extractor.
    nonisolated(unsafe) private static var warmedUp = false

    override func setUpWithError() throws {
        guard !Self.warmedUp else { return }
        let fixture = Self.pdf([.scan(Self.bitmap(Self.torque))])
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            if case .ready = DocumentTextExtractor.extract(from: fixture).outcome { Self.warmedUp = true; return }
            Thread.sleep(forTimeInterval: 2)
        }
        throw XCTSkip("Vision text recognition is not available on this host")
    }

    // MARK: Fixtures

    enum Content {
        case text([String])
        case scan(CGImage)
        case blank
    }

    /// Black text on white, `turns` quarter turns clockwise (a sideways scan).
    static func bitmap(_ lines: [String], turns: Int = 0, width: Int = 1275, height: Int = 1650, fontSize: CGFloat = 40) -> CGImage {
        let upright = turns % 2 == 0
        let context = CGContext(data: nil, width: upright ? width : height, height: upright ? height : width, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.translateBy(x: CGFloat(context.width) / 2, y: CGFloat(context.height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        draw(lines, in: context, top: CGFloat(height) - 120, left: 100, fontSize: fontSize, spacing: fontSize * 2)
        return context.makeImage()!
    }

    static func draw(_ lines: [String], in context: CGContext, top: CGFloat, left: CGFloat, fontSize: CGFloat, spacing: CGFloat) {
        context.setFillColor(gray: 0, alpha: 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ])
            context.textPosition = CGPoint(x: left, y: top - CGFloat(index) * spacing)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }

    static func pdf(_ pages: [Content], pageSize: CGSize = CGSize(width: 612, height: 792), password: String? = nil) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [:]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password + "-owner"
        }
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, info as CFDictionary)!
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let lines): draw(lines, in: context, top: pageSize.height - 100, left: 72, fontSize: 14, spacing: 28)
            case .scan(let image): context.draw(image, in: box)
            case .blank: break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func encode(_ image: CGImage, as type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func text(_ extraction: DocumentTextExtractor.Extraction, page: Int) -> String {
        extraction.pages.first { $0.ordinal == page }?.text ?? ""
    }

    // MARK: Text layer, scans, and mixes

    func testATypedPDFUsesItsTextLayerWithoutRecognition() {
        let extraction = DocumentTextExtractor.extract(from: Self.pdf([.text(Self.torque), .text(Self.winter)]))
        XCTAssertEqual(extraction.outcome, .ready(recognizedPages: 0, skippedPages: 0))
        XCTAssertEqual(extraction.pages.map(\.ordinal), [1, 2])
        XCTAssertTrue(text(extraction, page: 1).contains("110 ft-lb"))
        XCTAssertEqual(extraction.pages.map(\.ocrConfidence), [nil, nil], "a text layer is exact, so it carries no OCR confidence")
    }

    func testAScannedPDFIsRecognizedWithConfidence() {
        let extraction = DocumentTextExtractor.extract(from: Self.pdf([.scan(Self.bitmap(Self.torque))]))
        XCTAssertEqual(extraction.outcome, .ready(recognizedPages: 1, skippedPages: 0))
        XCTAssertTrue(text(extraction, page: 1).localizedCaseInsensitiveContains("lug nuts"))
        XCTAssertTrue(text(extraction, page: 1).contains("110"))
        let confidence = extraction.pages[0].ocrConfidence
        XCTAssertNotNil(confidence)
        XCTAssertGreaterThan(confidence ?? 0, 0.5)
    }

    func testAMixedPDFMakesEveryPageSearchableUnderItsOwnOrdinal() {
        let mixed = Self.pdf([.text(Self.torque), .scan(Self.bitmap(Self.winter)), .blank, .text(Self.winter)])
        let extraction = DocumentTextExtractor.extract(from: mixed)
        XCTAssertEqual(extraction.pages.map(\.ordinal), [1, 2, 3, 4])
        XCTAssertEqual(extraction.outcome, .ready(recognizedPages: 1, skippedPages: 0))
        XCTAssertNil(extraction.pages[0].ocrConfidence)
        XCTAssertNotNil(extraction.pages[1].ocrConfidence, "the scanned page is recognized and marked so")
        XCTAssertNil(extraction.pages[3].ocrConfidence)
        XCTAssertTrue(text(extraction, page: 1).contains("lug nuts"))
        XCTAssertTrue(text(extraction, page: 2).localizedCaseInsensitiveContains("fresh water"))
        XCTAssertEqual(text(extraction, page: 3), "", "a blank page between them keeps the numbering")
        XCTAssertTrue(text(extraction, page: 4).contains("fresh water"))

        // Passages cite the page they were read from.
        let passages = PassageChunker.passages(from: extraction.pages)
        let scanned = passages.filter { $0.page == 2 }
        XCTAssertFalse(scanned.isEmpty)
        XCTAssertTrue(scanned.allSatisfy { $0.ocrConfidence != nil })
        XCTAssertTrue(passages.filter { $0.page == 1 }.allSatisfy { $0.ocrConfidence == nil })
    }

    // MARK: Rotation

    func testSidewaysAndUpsideDownScansAreRecognized() {
        for turns in [1, 2, 3] {
            let extraction = DocumentTextExtractor.extract(from: Self.pdf([.scan(Self.bitmap(Self.torque, turns: turns))]))
            XCTAssertTrue(text(extraction, page: 1).localizedCaseInsensitiveContains("lug nuts"), "scan turned \(turns) quarter turns")
        }
    }

    func testAPageMarkedRotatedInThePDFIsReadUpright() throws {
        let document = try XCTUnwrap(PDFDocument(data: Self.pdf([.scan(Self.bitmap(Self.torque))])))
        document.page(at: 0)?.rotation = 90
        let rotated = try XCTUnwrap(document.dataRepresentation())
        let extraction = DocumentTextExtractor.extract(from: rotated)
        XCTAssertTrue(text(extraction, page: 1).localizedCaseInsensitiveContains("lug nuts"))
    }

    // MARK: Tables

    func testTableRowsKeepEachValueBesideItsLabel() {
        let width = 1275, height = 1650
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (row, cells) in [("Position", "Pressure"), ("Front axle", "35 psi"), ("Rear axle", "40 psi")].enumerated() {
            let y = CGFloat(height) - 200 - CGFloat(row) * 90
            Self.draw([cells.0], in: context, top: y, left: 100, fontSize: 40, spacing: 0)
            Self.draw([cells.1], in: context, top: y, left: 800, fontSize: 40, spacing: 0)
        }
        let extraction = DocumentTextExtractor.extract(from: Self.pdf([.scan(context.makeImage()!)]))
        let rows = text(extraction, page: 1).split(separator: "\n").map(String.init)
        XCTAssertTrue(rows.contains { $0.localizedCaseInsensitiveContains("front axle") && $0.contains("35") },
                      "the label and value share a row: \(rows)")
        XCTAssertTrue(rows.contains { $0.localizedCaseInsensitiveContains("rear axle") && $0.contains("40") })
    }

    // MARK: Images

    func testPhotographedPaperworkIsRecognizedInEachFormat() throws {
        let image = Self.bitmap(Self.torque)
        var tried = 0
        for type in ["public.jpeg", "public.png", "public.tiff", "public.heic"] {
            guard let data = Self.encode(image, as: type) else { continue }   // an encoder this host lacks
            tried += 1
            let extraction = DocumentTextExtractor.extract(from: data)
            XCTAssertEqual(extraction.pages.map(\.ordinal), [1], type)
            XCTAssertTrue(text(extraction, page: 1).localizedCaseInsensitiveContains("lug nuts"), type)
            XCTAssertNotNil(extraction.pages[0].ocrConfidence, type)
        }
        XCTAssertGreaterThanOrEqual(tried, 3)
    }

    func testARotatedPhotoIsRecognized() throws {
        let data = try XCTUnwrap(Self.encode(Self.bitmap(Self.winter, turns: 3), as: "public.jpeg"))
        XCTAssertTrue(text(DocumentTextExtractor.extract(from: data), page: 1).localizedCaseInsensitiveContains("fresh water"))
    }

    func testAMultiPageTIFFIsOnePagePerFrame() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, Self.bitmap(Self.torque), nil)
        CGImageDestinationAddImage(destination, Self.bitmap(Self.winter), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let extraction = DocumentTextExtractor.extract(from: data as Data)
        XCTAssertEqual(extraction.pages.map(\.ordinal), [1, 2])
        XCTAssertTrue(text(extraction, page: 1).contains("lug nuts"))
        XCTAssertTrue(text(extraction, page: 2).localizedCaseInsensitiveContains("fresh water"))
    }

    func testAPhotoWithNoTextIsNoUsableText() throws {
        let blank = Self.bitmap([])
        let data = try XCTUnwrap(Self.encode(blank, as: "public.png"))
        XCTAssertEqual(DocumentTextExtractor.extract(from: data).outcome, .noUsableText(.noText))
    }

    func testBytesThatAreNotAnImageAreUnreadableNotRetried() {
        XCTAssertEqual(DocumentTextExtractor.extract(from: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])).outcome, .noUsableText(.unreadable))
        XCTAssertEqual(DocumentTextExtractor.extract(from: Data()).outcome, .noUsableText(.unreadable))
    }

    // MARK: Empty and encrypted

    func testABlankPDFIsNoUsableText() {
        let extraction = DocumentTextExtractor.extract(from: Self.pdf([.blank, .blank]))
        XCTAssertEqual(extraction.outcome, .noUsableText(.noText))
        XCTAssertTrue(PassageChunker.passages(from: extraction.pages).isEmpty)
    }

    func testAPDFWithNoPagesIsNoUsableText() {
        let empty = Data("""
            %PDF-1.4
            1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
            2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj
            trailer<</Root 1 0 R/Size 3>>
            %%EOF
            """.utf8)
        guard case .noUsableText(let reason) = DocumentTextExtractor.extract(from: empty).outcome else {
            return XCTFail("a PDF without pages has nothing to read")
        }
        XCTAssertTrue([.empty, .unreadable].contains(reason))
    }

    func testAPasswordProtectedPDFIsEncryptedNotRetried() {
        let locked = Self.pdf([.text(Self.torque)], password: "secret")
        XCTAssertEqual(DocumentTextExtractor.extract(from: locked).outcome, .noUsableText(.encrypted))
    }

    // MARK: Caps

    func testAHugePageIsRenderedWithinTheBitmapCaps() throws {
        let giant = Self.pdf([.scan(Self.bitmap(Self.torque))], pageSize: CGSize(width: 14_400, height: 14_400))
        let page = try XCTUnwrap(PDFDocument(data: giant)?.page(at: 0))
        let image = try XCTUnwrap(DocumentTextExtractor.render(page))
        XCTAssertLessThanOrEqual(max(image.width, image.height), OCRPolicy.maximumRenderEdge)
        XCTAssertLessThanOrEqual(image.width * image.height, OCRPolicy.maximumRenderPixels)
        XCTAssertEqual(image.bitsPerPixel, 8, "gray, so a page costs at most about 5 MB")
    }

    func testALargeScannedPDFIsReadPageByPageWithinTheRecognitionAllowance() {
        let pages = (0..<6).map { _ in Content.scan(Self.bitmap(Self.torque)) }
        let giant = Self.pdf(pages, pageSize: CGSize(width: 14_400, height: 14_400))
        let extraction = DocumentTextExtractor.extract(from: giant, budget: OCRBudget(pages: 4, timeLimit: .seconds(240)))
        XCTAssertEqual(extraction.pages.count, 6)
        XCTAssertEqual(extraction.outcome, .ready(recognizedPages: 4, skippedPages: 2),
                       "the allowance stops recognition and says how many pages were left unread")
        XCTAssertEqual(extraction.pages.filter { !$0.text.isEmpty }.count, 4)
    }

    func testRecognitionStopsAtTheTimeAllowance() {
        let extraction = DocumentTextExtractor.extract(from: Self.pdf([.scan(Self.bitmap(Self.torque))]),
                                                       budget: OCRBudget(pages: 5, timeLimit: .zero))
        XCTAssertEqual(extraction.outcome, .noUsableText(.noText))
    }
}
#endif
