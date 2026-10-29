#if DEBUG
import UIKit
import SwiftData
import CampCore
import CampPersistence
import DocumentVault

/// `-document-assistant-fixture` (with `-navigation-ui-test`) puts a small synthetic water heater manual on the
/// fixture rig, plus another brand's manual that belongs to nothing. Pair it with `-assistant-ui-test ready
/// -assistant-generation-test document` to ask a question, see a cited source, and open it at the cited page.
/// Add `-document-source-states-fixture` to also open the Assistant on a canned chat, one answer each for a cited
/// source, a replaced document, a deleted document, and an uncited answer, so source states can be tapped without
/// a model or an index.
/// Everything is invented and lives only in the in-memory fixture library and a temporary search index.
enum DocumentAssistantFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-document-assistant-fixture") }

    static var showsSourceStates: Bool { ProcessInfo.processInfo.arguments.contains("-document-source-states-fixture") }

    private static let manualID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private static let furnaceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000C3")!
    private static let awningID = UUID(uuidString: "00000000-0000-4000-8000-0000000000D4")!

    /// One exchange per source state. The furnace manual is cited by an older checksum (it was "replaced") and
    /// the awning manual was never in the library (it was "deleted").
    @MainActor
    static func sourceStateExchanges(scope: AssistantScopeTarget, in context: ModelContext) -> [CampingExchange] {
        let manualChecksum = context.document(withID: manualID)?.checksum ?? ""
        func source(_ id: String, _ documentID: UUID, checksum: String, _ title: String, page: Int) -> DocumentSource {
            DocumentSource(id: id, documentID: documentID, checksum: checksum, title: title, category: "Manual", page: page)
        }
        func exchange(_ question: String, _ text: String, coverage: DocumentCoverage, cited: [DocumentSource] = [],
                      searched: [DocumentSource] = []) -> CampingExchange {
            CampingExchange(question: question, answer: CampingAnswer(text: text, sourceURL: nil, sources: cited, searched: searched, coverage: coverage),
                            scope: scope)
        }
        return [
            exchange("What does E4 mean?", "Error code E4 means the igniter failed to light.", coverage: .cited,
                     cited: [source("S1", manualID, checksum: manualChecksum, "Water Heater Manual", page: 2)],
                     searched: [source("S2", manualID, checksum: manualChecksum, "Water Heater Manual", page: 3)]),
            exchange("How do I light the furnace?", "Press the ignition button for ten seconds.", coverage: .cited,
                     cited: [source("S1", furnaceID, checksum: "replaced-after-this-answer", "Furnace Manual", page: 5)]),
            exchange("How do I retract the awning?", "Turn the crank clockwise until it stops.", coverage: .cited,
                     cited: [source("S1", awningID, checksum: "deleted", "Awning Manual", page: 7)]),
            exchange("Any tips for a rainy trip?", "Keep a tarp handy and pitch it before the rain starts.", coverage: .uncited,
                     searched: [source("S1", manualID, checksum: manualChecksum, "Water Heater Manual", page: 3)])
        ]
    }

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
        if showsSourceStates {
            let furnace = try payload(filename: "Furnace Manual.pdf", pages: [("", "Furnace Owner's Manual"), ("", "Ignition")])
            try StoredDocument.add(DocumentMetadata(title: "Furnace Manual", category: .manual), contents: furnace, rig: rig, in: context)
                .documentID = furnaceID
        }
        // Belongs to no rig, so it must never be searched for this one even though it also explains E4.
        let other = try payload(filename: "Brand X Water Heater.pdf", pages: [
            ("TROUBLESHOOTING", "Error code E4 on a Brand X water heater means the thermostat failed.\nReplace the thermostat.")
        ])
        try StoredDocument.add(DocumentMetadata(title: "Brand X Water Heater Manual", category: .manual), contents: other, in: context)
            .documentID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    }

    private static func payload(filename: String, pages: [(heading: String, body: String)]) throws -> DocumentPayload {
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
