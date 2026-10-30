#if DEBUG
import Foundation
import CoreGraphics
import CoreText

/// Invented camping manuals, drawn into PDFs at run time for the performance baseline. Nothing here comes from a
/// real document, and the same seed always yields the same files. A "typed" PDF carries a text layer. A "scanned"
/// PDF holds only a picture of the page, so reading it needs text recognition, as a photographed manual does.
enum SyntheticPDFCorpus {
    struct Item {
        var name: String
        var data: Data
        var pages: Int
        var isScanned: Bool
        /// A fault code that exists only in this document, for the retrieval checks.
        var code: String
    }

    /// Deterministic: xorshift seeded from the document number.
    private struct Generator {
        var state: UInt64
        init(seed: Int) { state = UInt64(seed) &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }
    }

    private static let components = ["water heater", "furnace", "refrigerator", "awning", "slide-out", "leveling jack", "converter", "inverter",
                                     "propane regulator", "fresh water pump", "black tank valve", "roof air conditioner", "stabilizer jack", "battery monitor"]
    private static let actions = ["Turn the unit off and wait five minutes before trying again.", "Check that the propane supply valve is fully open.",
                                  "Inspect the electrode for soot and clean it with a dry cloth.", "Confirm the battery voltage is above twelve volts.",
                                  "Drain the lines and open every low point drain before winter storage.", "Replace the filter if it looks discolored.",
                                  "Retract the awning fully before driving or in strong wind.", "Contact a service technician if the fault repeats."]
    private static let faults = ["the igniter failed to light", "the thermostat sensor circuit is open", "the pressure switch did not close",
                                 "the control board lost communication", "the motor drew too much current", "the high limit switch tripped"]

    /// A typed manual. The fault code is unique per document number.
    static func manual(number: Int, pages: Int) -> Item {
        Item(name: "synthetic-manual-\(number).pdf", data: typedPDF(pageTexts(number: number, pages: pages)), pages: pages, isScanned: false, code: "K\(number)")
    }

    /// A manual that is only pictures of pages.
    static func scan(number: Int, pages: Int) -> Item {
        Item(name: "synthetic-scan-\(number).pdf", data: scannedPDF(texts: pageTexts(number: number, pages: pages)), pages: pages, isScanned: true, code: "K\(number)")
    }

    private static func pageTexts(number: Int, pages: Int) -> [String] {
        var random = Generator(seed: number)
        let component = components[number % components.count]
        return (1...pages).map { page in
            var lines = ["Model \(100 + number) \(component) owner's manual, section \(page)."]
            if page == 1 { lines.append("Fault code K\(number) means \(faults[number % faults.count]) on the \(component).") }
            for _ in 0..<7 {
                lines.append("\(actions[random.next(actions.count)]) The \(components[random.next(components.count)]) on this model uses part number \(10 + random.next(80))-\(1000 + random.next(9000))-B.")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: Drawing

    private static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    private static func typedPDF(_ pages: [String]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = letter
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for text in pages {
            context.beginPDFPage(nil)
            draw(text, in: context, rect: letter.insetBy(dx: 54, dy: 54), fontSize: 12)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func scannedPDF(texts: [String]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = letter
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        // About 150 dpi gray bitmaps, the way a phone scan of a letter page arrives.
        let width = 1275, height = 1650
        for text in texts {
            autoreleasepool {
                guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                bitmap.setFillColor(gray: 1, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let scale = CGFloat(width) / letter.width
                bitmap.scaleBy(x: scale, y: scale)
                draw(text, in: bitmap, rect: letter.insetBy(dx: 54, dy: 54), fontSize: 12)
                context.beginPDFPage(nil)
                if let image = bitmap.makeImage() { context.draw(image, in: letter) }
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, in context: CGContext, rect: CGRect, fontSize: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        context.setFillColor(gray: 0, alpha: 1)
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}
#endif
