import XCTest
@testable import DocumentSearch

/// English-only document Q&A: which passages are admitted, how a document's coverage is labeled, and which
/// questions are turned away. The rules run against a fake detector; the NaturalLanguage cases check the
/// real adapter on realistic text.
final class EnglishOnlyTests: XCTestCase {
    /// Reads a marker word as the language: "agua" is Spanish, "wasser" German, "blurry" unsure.
    struct FakeDetector: LanguageDetecting {
        func hypotheses(for text: String) -> [String: Double] {
            let lower = text.lowercased()
            if lower.contains("agua") || lower.contains("calentador") { return ["es": 0.97, "en": 0.01] }
            if lower.contains("wasser") { return ["de": 0.95, "en": 0.02] }
            if lower.contains("smudge") { return ["en": 0.4, "fr": 0.3, "it": 0.2] }
            if lower.contains("qwerty") { return ["fr": 0.9, "en": 0.05] }
            return ["en": 0.98]
        }
    }

    private let detector = FakeDetector()

    private func passage(_ text: String, page: Int) -> IndexedPassage { IndexedPassage(text: text, page: page) }

    private let english = "Close the drain valve and open the water heater bypass before you pour in the antifreeze."
    private let spanish = "Cierre la válvula de drenaje y abra el agua del calentador antes de verter el anticongelante."
    private let german = "Schließen Sie das Ventil und prüfen Sie das Wasser im Boiler vor dem Winter sorgfältig."

    // MARK: Passages

    func testAnEnglishDocumentIsAdmittedInFull() {
        let result = DocumentLanguagePolicy.admit([passage(english, page: 1), passage(english + " Then run the pump.", page: 2)], using: detector)
        XCTAssertEqual(result.coverage, .full)
        XCTAssertEqual(result.admitted.count, 2)
        XCTAssertEqual(result.language, "en")
    }

    func testABilingualDocumentContributesItsEnglishPassagesAndIsPartial() {
        let result = DocumentLanguagePolicy.admit([passage(english, page: 1), passage(spanish, page: 2), passage(german, page: 3)], using: detector)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertEqual(result.admitted.map(\.page), [1])
        XCTAssertEqual(result.excludedCount, 2)
        XCTAssertEqual(result.language, "en")
    }

    func testADocumentWithNoEnglishIsEnglishOnlyAndRecordsItsLanguage() {
        let result = DocumentLanguagePolicy.admit([passage(spanish, page: 1), passage(spanish + " Gracias.", page: 2)], using: detector)
        XCTAssertEqual(result.coverage, .englishOnly)
        XCTAssertTrue(result.admitted.isEmpty)
        XCTAssertEqual(result.language, "es")
    }

    func testUncertainTextIsNotAdmittedAndIsNotCalledAnotherLanguage() {
        let result = DocumentLanguagePolicy.admit([passage("The smudge covers most of this page of the printed manual text.", page: 1)], using: detector)
        XCTAssertEqual(result.coverage, .englishOnly)
        XCTAssertEqual(result.language, "und")
    }

    func testACodeRowTakesTheLanguageOfItsPage() {
        let table = "E4 | Ignition failure\nF13 | Low voltage"
        let onEnglishPage = DocumentLanguagePolicy.admit([passage(english, page: 1), passage(table, page: 1)], using: detector)
        XCTAssertEqual(onEnglishPage.admitted.count, 2, "codes beside English prose are admitted")
        XCTAssertEqual(onEnglishPage.coverage, .full)

        let onSpanishPage = DocumentLanguagePolicy.admit([passage(english, page: 1), passage(spanish, page: 2), passage(table, page: 2)], using: detector)
        XCTAssertEqual(onSpanishPage.admitted.map(\.page), [1], "codes beside Spanish prose are not")
    }

    func testACodeRowOnAPageWithNoProseTakesTheDocumentsLanguage() {
        let table = passage("E4 | Ignition failure", page: 9)
        XCTAssertEqual(DocumentLanguagePolicy.admit([passage(english, page: 1), table], using: detector).admitted.count, 2)
        XCTAssertEqual(DocumentLanguagePolicy.admit([passage(spanish, page: 1), table], using: detector).admitted.count, 0)
        XCTAssertEqual(DocumentLanguagePolicy.admit([table], using: detector).coverage, .englishOnly,
                       "nothing says it is English, so nothing is admitted")
    }

    func testCodesAndPartNumbersDoNotDecideTheLanguage() {
        // Digits, single letters, and short codes are not prose. Only the words around them are judged.
        XCTAssertEqual(DocumentLanguagePolicy.prose(in: "Error E4 on unit 11-2047-B: replace the anode rod"),
                       ["Error", "on", "unit", "replace", "the", "anode", "rod"])
        XCTAssertTrue(DocumentLanguagePolicy.prose(in: "E4? A-203 F13 11-2047-B").isEmpty)
    }

    func testNonEnglishPassagesNeverReachSearchIncludingFullTextSearch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("english-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try DocumentSearchIndex(url: url)
        let admission = DocumentLanguagePolicy.admit([passage(english, page: 1), passage(spanish, page: 2), passage(german, page: 3)], using: detector)
        let document = IndexedDocument(id: "d", checksum: "c", extractionVersion: 1, chunkingVersion: PassageChunker.version,
                                       language: admission.language,
                                       outcome: admission.coverage == .partial ? .englishPartial : .ready)
        try await index.publish(document, passages: admission.admitted, embedding: DeterministicEmbeddingProvider())

        for query in ["anticongelante", "calentador", "válvula drenaje", "Boiler", "Schließen"] {
            let hits = try await index.search(query, documentIDs: ["d"], embedding: DeterministicEmbeddingProvider()).hits
            XCTAssertFalse(hits.contains { $0.page == 2 || $0.page == 3 }, "\(query) matched another language")
        }
        let english = try await index.search("antifreeze bypass", documentIDs: ["d"]).hits
        XCTAssertEqual(english.first?.page, 1)
        let record = try await index.indexedDocuments()["d"]
        XCTAssertEqual(record?.outcome, .englishPartial, "the label survives a relaunch")
    }

    // MARK: Questions

    func testAQuestionInAnotherLanguageIsTurnedAway() {
        XCTAssertEqual(DocumentLanguagePolicy.check(question: "¿Qué significa el código E4 en mi calentador de agua?", using: detector), .needsEnglish)
        XCTAssertEqual(DocumentLanguagePolicy.check(question: "What does the code E4 mean on my water heater?", using: detector), .proceed)
    }

    func testShortCodeQuestionsAreNeverRejected() {
        // Even a detector that is sure the text is French must not decide a question with no prose.
        struct Sure: LanguageDetecting { func hypotheses(for text: String) -> [String: Double] { ["fr": 1] } }
        for question in ["E4?", "e4", "A-203", "F13 ?", "11-2047-B", "Qué es E4", "code E4"] {
            XCTAssertEqual(DocumentLanguagePolicy.check(question: question, using: Sure()), .proceed, question)
        }
    }

    func testAnUnreadableQuestionProceeds() {
        struct Blank: LanguageDetecting { func hypotheses(for text: String) -> [String: Double] { [:] } }
        XCTAssertEqual(DocumentLanguagePolicy.check(question: "how do I winterize the water lines", using: Blank()), .proceed)
    }

    func testTheExplanationInvitesAnEnglishQuestion() {
        XCTAssertTrue(DocumentLanguagePolicy.englishOnlyExplanation.contains("English"))
    }

    // MARK: NaturalLanguage

    func testTheSystemDetectorKeepsEnglishAndDropsSpanishAndGermanPages() {
        let real = NaturalLanguageDetector()
        let pages = [
            ExtractedPage(ordinal: 1, text: "WINTERIZING\nClose the drain valve and open the water heater bypass before you pour in the antifreeze. Run the pump until pink fluid flows from every faucet."),
            ExtractedPage(ordinal: 2, text: "INVIERNO\nCierre la válvula de drenaje y abra la derivación del calentador de agua antes de verter el anticongelante. Haga funcionar la bomba hasta que salga líquido rosado."),
            ExtractedPage(ordinal: 3, text: "WINTER\nSchließen Sie das Ablassventil und öffnen Sie die Umgehung des Warmwasserbereiters, bevor Sie das Frostschutzmittel einfüllen. Lassen Sie die Pumpe laufen."),
            ExtractedPage(ordinal: 4, text: "ERROR CODES\nE4 | Ignition failure\nF13 | Low battery voltage")
        ]
        let result = DocumentLanguagePolicy.admit(PassageChunker.passages(from: pages), using: real)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertEqual(Set(result.admitted.compactMap(\.page)), [1, 4], "English prose and the code table beside it")
    }

    func testTheSystemDetectorKeepsCodesInsideEnglishText() {
        let text = "If the display shows E4, the igniter failed to light. Part 11-2047-B is the anode rod; error F13 means low voltage. Turn the unit off and wait five minutes."
        let result = DocumentLanguagePolicy.admit([passage(text, page: 12)], using: NaturalLanguageDetector())
        XCTAssertEqual(result.coverage, .full)
    }

    func testTheSystemDetectorTurnsAwaySpanishQuestionsButNotCodes() {
        let real = NaturalLanguageDetector()
        XCTAssertEqual(DocumentLanguagePolicy.check(question: "¿Qué significa el código E4 en mi calentador de agua?", using: real), .needsEnglish)
        XCTAssertEqual(DocumentLanguagePolicy.check(question: "Wie winterfest mache ich die Wasserleitungen meines Wohnwagens?", using: real), .needsEnglish)
        for question in ["E4?", "A-203", "What does fault code E4 mean on my water heater?", "How do I winterize the water lines?"] {
            XCTAssertEqual(DocumentLanguagePolicy.check(question: question, using: real), .proceed, question)
        }
    }

    func testNoisyScannedEnglishIsNotMistakenForAnotherLanguage() {
        let noisy = "Tbe igniter fai1s to l1ght wben tbe supp1y va1ve is c1osed. Cbeck tbe pr0pane tank and re-open tbe va1ve s1ow1y."
        let result = DocumentLanguagePolicy.admit([passage(noisy, page: 3)], using: NaturalLanguageDetector())
        XCTAssertTrue(result.admitted.isEmpty || result.coverage == .full)
        XCTAssertNotEqual(result.language, "es")
    }
}
