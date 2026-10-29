#if DEBUG
import UIKit
import SwiftData
import CampPersistence
import DocumentVault

/// `-document-assistant-fixture` (with `-navigation-ui-test`) puts a small synthetic water heater manual on the
/// fixture rig, plus another brand's manual that belongs to nothing. Pair it with `-assistant-ui-test ready
/// -assistant-generation-test document` to ask a question, see a cited source, and open it at the cited page.
/// Everything is invented and lives only in the in-memory fixture library and a temporary search index.
enum DocumentAssistantFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-document-assistant-fixture") }

    @MainActor
    static func seed(rig: Rig, in context: ModelContext) throws {
        let manual = try payload(filename: "Water Heater Manual.pdf", pages: [
            ("", "Aqua-Glo AG6 Water Heater\nOwner's Manual\nRead all instructions before use."),
            ("TROUBLESHOOTING", "Error code E4 means the water heater igniter failed to light.\nTurn the unit off and wait five minutes before retrying."),
            ("WINTERIZING", "Drain the fresh water tank and open all low point drains\nbefore winter storage to prevent freeze damage.")
        ])
        // Fixed IDs, so a relaunch finds the same documents in the (persistent) temporary index and reuses them.
        try StoredDocument.add(DocumentMetadata(title: "Water Heater Manual", category: .manual), contents: manual, rig: rig, in: context)
            .documentID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
        // Belongs to no rig, so it must never be searched for this one even though it also explains E4.
        let other = try payload(filename: "Brand X Water Heater.pdf", pages: [
            ("TROUBLESHOOTING", "Error code E4 on a Brand X water heater means the thermostat failed.\nReplace the thermostat.")
        ])
        try StoredDocument.add(DocumentMetadata(title: "Brand X Water Heater Manual", category: .manual), contents: other, in: context)
            .documentID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    }

    static func payload(filename: String, pages: [(heading: String, body: String)]) throws -> DocumentPayload {
        // Rendering stamps a creation date, so the first render is kept and reused: the same bytes mean the same
        // checksum on the next launch, which is what lets the index be reused.
        let cached = URL.temporaryDirectory.appending(path: "DocumentAssistantFixture-\(filename)")
        if let data = try? Data(contentsOf: cached) { return try DocumentPayload(bytes: data, filename: filename) }
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in pages {
                context.beginPage()
                var y: CGFloat = 72
                if !page.heading.isEmpty {
                    let heading = page.heading as NSString
                    heading.draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
                    y += 44
                }
                (page.body as NSString).draw(in: CGRect(x: 72, y: y, width: 468, height: 400),
                                             withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
        }
        try? data.write(to: cached)
        return try DocumentPayload(bytes: data, filename: filename)
    }
}
#endif
